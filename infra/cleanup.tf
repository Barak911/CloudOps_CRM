# Pre-destroy cleanup for Kubernetes-created AWS resources
#
# Problem: Kubernetes creates AWS resources (NLBs from LoadBalancer Services)
# that Terraform doesn't manage. If EKS is destroyed first, these resources
# become orphaned and continue to incur charges.
#
# Note: EBS volumes are intentionally preserved across destroy/apply cycles
# to retain persistent data (MongoDB, Elasticsearch). They are low-cost and
# can be manually cleaned up when no longer needed.
#
# Solution: This null_resource runs a cleanup script BEFORE the EKS cluster
# is destroyed, giving Kubernetes time to deprovision its NLBs.

resource "null_resource" "k8s_cleanup" {
  # Re-run cleanup if the cluster changes
  triggers = {
    cluster_name = module.eks.cluster_name
    region       = var.aws_region
  }

  # On destroy: clean up Kubernetes-created AWS resources (NLBs) before EKS goes down
  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      set -e

      CLUSTER="${self.triggers.cluster_name}"
      REGION="${self.triggers.region}"

      echo "=== Pre-destroy cleanup: removing Kubernetes-created AWS resources ==="
      echo "NOTE: EBS volumes are preserved (not deleted on destroy)"

      # Update kubeconfig for the cluster
      aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" 2>/dev/null || {
        echo "WARN: Could not connect to EKS cluster (may already be gone). Falling back to direct AWS cleanup."

        # Direct AWS cleanup: delete NLBs tagged with the cluster
        echo "Cleaning up orphaned Load Balancers..."
        LB_ARNS=$(aws elbv2 describe-load-balancers --region "$REGION" \
          --query "LoadBalancers[].LoadBalancerArn" --output text 2>/dev/null || echo "")
        for ARN in $LB_ARNS; do
          CLUSTER_TAG=$(aws elbv2 describe-tags --resource-arns "$ARN" --region "$REGION" \
            --query "TagDescriptions[].Tags[?Key=='kubernetes.io/cluster/$CLUSTER'].Value" \
            --output text 2>/dev/null || echo "")
          if [ -n "$CLUSTER_TAG" ]; then
            echo "  Deleting LB: $ARN"
            aws elbv2 delete-load-balancer --load-balancer-arn "$ARN" --region "$REGION" 2>/dev/null || true
          fi
        done

        echo "=== Direct AWS cleanup complete ==="
        exit 0
      }

      # --- Kubernetes-aware cleanup (cluster is still reachable) ---

      # 1. Delete all Helm releases across namespaces to trigger graceful cleanup
      echo "Removing Helm releases..."
      for NS in crm monitoring argocd; do
        RELEASES=$(helm list -n "$NS" -q 2>/dev/null || echo "")
        for REL in $RELEASES; do
          echo "  Uninstalling $REL from $NS..."
          helm uninstall "$REL" -n "$NS" --wait --timeout 2m 2>/dev/null || true
        done
      done

      # 2. Delete any remaining LoadBalancer services (triggers NLB deletion)
      echo "Deleting LoadBalancer services..."
      LB_SVCS=$(kubectl get svc --all-namespaces -o json 2>/dev/null | \
        jq -r '.items[] | select(.spec.type=="LoadBalancer") | "\(.metadata.namespace)/\(.metadata.name)"' 2>/dev/null || echo "")
      for SVC in $LB_SVCS; do
        NS=$(echo "$SVC" | cut -d/ -f1)
        NAME=$(echo "$SVC" | cut -d/ -f2)
        echo "  Deleting svc/$NAME in $NS..."
        kubectl delete svc "$NAME" -n "$NS" --timeout=60s 2>/dev/null || true
      done

      # 3. Wait for NLBs to finish deregistering (AWS takes ~30-60s)
      echo "Waiting for Load Balancers to be fully deprovisioned..."
      for i in $(seq 1 12); do
        CLUSTER_LB_COUNT=0
        LB_ARNS=$(aws elbv2 describe-load-balancers --region "$REGION" \
          --query "LoadBalancers[].LoadBalancerArn" --output text 2>/dev/null || echo "")
        for ARN in $LB_ARNS; do
          [ -z "$ARN" ] && continue
          CLUSTER_TAG=$(aws elbv2 describe-tags --resource-arns "$ARN" --region "$REGION" \
            --query "TagDescriptions[].Tags[?Key=='kubernetes.io/cluster/$CLUSTER'].Value" \
            --output text 2>/dev/null || echo "")
          if [ -n "$CLUSTER_TAG" ]; then
            CLUSTER_LB_COUNT=$((CLUSTER_LB_COUNT + 1))
          fi
        done
        if [ "$CLUSTER_LB_COUNT" -eq 0 ]; then
          echo "  All cluster Load Balancers deprovisioned."
          break
        fi
        echo "  Still $CLUSTER_LB_COUNT cluster LB(s) remaining... waiting 10s ($i/12)"
        sleep 10
      done

      echo "=== Pre-destroy cleanup complete ==="
    EOT
  }

  depends_on = [module.eks]
}

# Force EKS to wait for cleanup before being destroyed
# The EKS module's node groups and addons depend on cleanup completing first
resource "null_resource" "eks_destroy_dependency" {
  triggers = {
    cluster_name = module.eks.cluster_name
  }

  depends_on = [null_resource.k8s_cleanup]
}
