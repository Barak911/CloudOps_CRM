# Troubleshooting Guide

## EKS kubectl Access

**Problem:** `kubectl get nodes` returns "you must be logged in to the server (Unauthorized)"

**Solution:**
```bash
CLUSTER_NAME=<your-cluster-name>
AWS_REGION=<your-region>

# Get your IAM ARN and create access entry
PRINCIPAL_ARN=$(aws sts get-caller-identity --query Arn --output text)
aws eks create-access-entry --cluster-name $CLUSTER_NAME --region $AWS_REGION --principal-arn $PRINCIPAL_ARN
aws eks associate-access-policy --cluster-name $CLUSTER_NAME --region $AWS_REGION \
  --principal-arn $PRINCIPAL_ARN \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster

# Update kubeconfig and verify
aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION
kubectl get nodes
```

The cluster creator already gets an access entry via `enable_cluster_creator_admin_permissions = true`, so this is only needed for a *different* IAM principal.

---

## Terraform: state lock or "Failed to persist state" mid-apply

**Problem:** Network blip kills a long apply (EKS cluster create takes 10–15 min; one DNS failure during the wait fails the whole apply with an unrecoverable state-save error). The state lock then survives.

**Solution:**
```bash
# 1. Find and release the lock
LOCK_ID=$(aws s3 cp s3://YOUR_STATE_BUCKET/YOUR_KEY/terraform.tfstate.tflock - 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['ID'])")
terraform force-unlock -force "$LOCK_ID"

# 2. If errored.tfstate was written locally, push it back
[ -f errored.tfstate ] && terraform state push errored.tfstate && rm errored.tfstate

# 3. If the cluster (or KMS alias, or any other resource) was created in AWS
#    but never made it into state, import it before re-applying:
terraform import 'module.eks.aws_eks_cluster.this[0]' <cluster-name>
terraform import 'module.eks.module.kms.aws_kms_alias.this["cluster"]' alias/eks/<cluster-name>

# 4. Re-apply
terraform apply
```

For genuinely flaky networks, prefer a state bucket in the same region as the cluster (DNS is fewer hops and more consistent), and run long applies in `screen`/`tmux` so a network change doesn't SIGHUP terraform.

---

## Karpenter: NodeClass stuck in InstanceProfileReady=Unknown

**Problem:** Karpenter v1 NodeClass shows `InstanceProfileReady: Unknown, error: getting instance profile "<cluster>_<random>", iam:GetInstanceProfile AccessDenied`.

**Cause:** With the NodeClass `role:` field set, Karpenter tries to *create* and manage an instance profile dynamically — that requires `iam:CreateInstanceProfile` / `iam:AddRoleToInstanceProfile` on the controller, which a tight policy won't have.

**Solution:** Use the pre-created instance profile from `infra/karpenter.tf` by setting `instanceProfile:` instead of `role:` on the NodeClass:
```yaml
spec:
  instanceProfile: <cluster>-karpenter-node   # not: role: <cluster>-karpenter-node
```
`podManagementPolicy` and `role`/`instanceProfile` on NodeClass are immutable; switching them requires `kubectl delete ec2nodeclass default && kubectl delete nodepool default` then re-apply.

---

## Karpenter: NodeClaim stuck in Launched=Unknown, ec2:CreateFleet AccessDenied

**Problem:** `error creating fleet: ec2:CreateFleet on resource arn:...:fleet/* AccessDenied`.

**Cause:** The Karpenter controller policy was scoped per-action with too narrow a Resource list. `ec2:CreateFleet` touches `fleet/`, `launch-template/`, `instance/`, `volume/`, `network-interface/`, `image/`, `snapshot/`, `security-group/`, `subnet/`, and `spot-instances-request/` all in the same call — if any one is missing from the policy's Resource list, the whole call fails.

**Solution:** Make sure the `AllowScopedEC2InstanceAccessActions` statement in `karpenter.tf` covers the full resource set. See the live policy and Karpenter's canonical CloudFormation template at https://karpenter.sh/v1.1/reference/cloudformation/.

---

## PrometheusRule rejected with `function "mul" not defined`

**Problem:** The Prometheus operator logs `Invalid rule ... template: function "mul" not defined` and the rule never reaches Prometheus.

**Cause:** Alert annotation templates use Sprig functions (`mul`, `add`, etc.) that aren't available in the operator's restricted template subset.

**Solution:** Use Prometheus' built-in template functions instead — `humanizePercentage` for 0..1 → percentage, `humanizeDuration` for seconds → human time, etc.

```yaml
# Bad:
description: "Used {{ printf "%.0f%%" (mul $value 100) }} of capacity."
# Good:
description: "Used {{ $value | humanizePercentage }} of capacity."
```

The whole PrometheusRule is rejected if *any* annotation fails to template — check operator logs immediately after a sync:
```bash
kubectl logs -n monitoring -l app=kube-prometheus-stack-operator --tail=50 \
  | grep -i "invalid rule"
```

---

## NetworkPolicy: pod can't reach a service it should be allowed to

**Problem:** Default-deny is in place; a workload that should be allowed (per a NetworkPolicy `from:`/`to:` rule) still can't connect.

**Triage checklist:**

```bash
# 1. Is the policy actually present and matching the right pod selector?
kubectl get networkpolicy -A
kubectl get pod <pod> -n <ns> -o jsonpath='{.metadata.labels}'

# 2. Are you missing the *other* direction? Default-deny blocks BOTH ingress
#    and egress in crm namespace; an ingress allow on the recipient is not
#    enough — the sender also needs an egress allow.
#    Common gotcha: mongodb-to-mongodb (replica set replication, init Job)
#    needs an EGRESS rule from app=mongodb to app=mongodb on 27017, not just
#    an ingress rule on the recipient.

# 3. Test connectivity from inside the pod:
kubectl exec -n <ns> <pod> -- bash -c "timeout 5 bash -c 'cat < /dev/tcp/<host>/<port>' 2>&1 || echo BLOCKED"

# 4. VPC CNI enforcement uses eBPF and reconciles in <5s; if the policy is
#    present and connectivity still fails after that, suspect the selector,
#    not the CNI.
```

---

## ArgoCD: chart change pushed but live state still shows the old version

**Problem:** You pushed a chart change to `main`; ArgoCD says "Synced" but the live resource still matches the old chart.

**Cause:** ArgoCD's manifest cache. The Application is "Synced" against a *previous* revision that was cached.

**Solution:**
```bash
kubectl annotate application <name> -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite
# Then trigger a sync if auto-sync hasn't already
kubectl patch application <name> -n argocd \
  --type=merge -p '{"operation":{"sync":{"prune":true}}}'
```

---

## ArgoCD: Helm `helm.sh/hook` Job never runs on sync

**Problem:** A chart Job annotated `helm.sh/hook: post-install,post-upgrade` doesn't appear in ArgoCD's resource list and never fires.

**Cause:** ArgoCD does not translate Helm hooks into its own sync hooks automatically. The Job has to also carry the ArgoCD-native annotation.

**Solution:**
```yaml
annotations:
  helm.sh/hook: post-install,post-upgrade           # for `helm install/upgrade`
  helm.sh/hook-delete-policy: before-hook-creation
  argocd.argoproj.io/hook: PostSync                 # for ArgoCD-managed reconcile
  argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
```

---

## StatefulSet update fails: "podManagementPolicy ... is not supported"

**Problem:** Changing `podManagementPolicy` (e.g. from `OrderedReady` to `Parallel`) errors out on apply: `field is immutable`.

**Cause:** `podManagementPolicy` is immutable on a live StatefulSet.

**Solution:** Delete the StatefulSet (cascading or orphan), then let the chart/ArgoCD recreate it:
```bash
kubectl delete statefulset <name> -n <ns>
# (For data-loss-tolerant rollouts:)
kubectl delete pvc -n <ns> -l <selector>
# Then trigger an ArgoCD sync.
```

---

## ECR push from CI works but ArgoCD pulls fail with `manifest unknown`

**Problem:** Image was pushed but Pod can't pull it.

**Triage:**
- Did CI write to `k8s/values/image-state.yaml`? `git log -1 -- k8s/values/image-state.yaml`.
- Is the digest correct? `aws ecr describe-images --repository-name crm-app --image-ids imageTag=<tag>` → `imageDetails[0].imageDigest`.
- Is the node IAM role allowed to pull from ECR? The Karpenter node role and the managed node group role both attach `AmazonEC2ContainerRegistryReadOnly`. If neither is present, the kubelet's image pull fails with `repository does not exist or no pull access`.

---

## Port Conflicts (Local Development)

**Problem:** Port 5000 in use on macOS (AirPlay Receiver).

**Solution:** The docker-compose files map to port 5001 externally. Access the API at `http://localhost:5001`.

---

## Docker Build Issues

**Problem:** `externally-managed-environment` error on macOS.

**Solution:**
```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

---

## ECR Authentication

**Problem:** Docker push fails with auth error.

**Solution:**
```bash
aws ecr get-login-password --region <region> | \
  docker login --username AWS --password-stdin <account-id>.dkr.ecr.<region>.amazonaws.com
```

---

## GitHub Actions CI/CD

**Problem:** `eks:DescribeCluster` AccessDeniedException or `Could not assume role with OIDC`.

**Solution:**
- The bootstrap workflow assumes `AWS_BOOTSTRAP_ROLE_ARN` and requires `environment: production` on the job — without that block the OIDC subject won't match `repo:.../*:environment:production` and the assume-role fails. Confirm the `production` environment exists in `Settings → Environments`.
- The day-2 CI workflow assumes `AWS_CI_ROLE_ARN`; trust is pinned to `refs/heads/main`. A push from a non-main branch will fail to assume the role by design.

### Required GitHub Secrets

| Secret | Value |
|--------|-------|
| `AWS_BOOTSTRAP_ROLE_ARN` | `terraform output github_actions_bootstrap_role_arn` (used by bootstrap-cluster.yml and cleanup-deployment.yml; gated by `environment:production`) |
| `AWS_CI_ROLE_ARN` | `terraform output github_actions_ci_role_arn` (used by ci.yml; ECR push only, trust scoped to `refs/heads/main`) |
| `EKS_CLUSTER_NAME` | Your EKS cluster name |

### Required GitHub Environments

| Environment | Why it exists |
|-------------|---------------|
| `production` | Gates the OIDC trust on `AWS_BOOTSTRAP_ROLE_ARN`. Workflows that need cluster admin must declare `environment: production` at the job level. Add required reviewers here for production-grade gating. |

---

## Cost Management

Always destroy resources after testing:

```bash
# 1. Run cleanup-deployment.yml workflow first
gh workflow run cleanup-deployment.yml --repo $REPO --ref main \
  --field aws_region=us-east-1 \
  --field confirm_deletion=DELETE \
  --field delete_pvcs=true

# 2. Then destroy infrastructure
cd infra && terraform destroy

# 3. If ECR refuses to delete because it has images:
aws ecr delete-repository --repository-name crm-app --region <region> --force
terraform state rm aws_ecr_repository.demo_crm

# 4. Optionally delete the state bucket (versioned, so you need to delete
#    all object versions first):
aws s3api list-object-versions --bucket YOUR_STATE_BUCKET --output json \
  | python3 -c "
import sys, json, subprocess
d = json.load(sys.stdin)
for it in (d.get('Versions') or []) + (d.get('DeleteMarkers') or []):
    subprocess.run(['aws','s3api','delete-object',
                    '--bucket','YOUR_STATE_BUCKET',
                    '--key',it['Key'],'--version-id',it['VersionId']])
"
aws s3 rb s3://YOUR_STATE_BUCKET
```

EKS clusters incur hourly charges even when idle. Karpenter spot nodes consolidate after `consolidateAfter: 1m` of being empty.
