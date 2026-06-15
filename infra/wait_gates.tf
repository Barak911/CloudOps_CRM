# In-cluster wait gates (the "wait-Job pattern", or "out-of-process readiness
# barrier"). Replaces `helm_release { wait = true }` for the substrate charts.
#
# Why: `wait = true` blocks INSIDE the terraform process, holding the state
# lock for the entire wait window. Across 5 substrate helm_releases that's
# 15+ minutes of held lock — a single SIGKILL leaves a stale lock that needs
# manual `terraform force-unlock` recovery. With `wait = false` + a wait Job,
# each helm_release returns in seconds; terraform's blocking work moves to
# `kubernetes_job` resources whose actual readiness check (`kubectl wait
# --for=condition=Available ...`) runs IN-CLUSTER. The terraform lock is
# held only briefly per resource.
#
# The pattern is from lablabs/terraform-aws-eks-universal-addon and is the
# convention modern eks-addon terraform modules use.
#
# This file owns the shared RBAC (one ClusterRole, one SA, one Binding). Each
# wait Job in helm_releases.tf / argocd_bootstrap.tf reuses these.

locals {
  # All wait Jobs run kubectl from the same image so any future kubectl
  # version bump is one-line. Pinned, not floating.
  wait_image = "registry.k8s.io/kubectl:v1.31.0"
}

resource "kubernetes_namespace_v1" "tf_bootstrap" {
  metadata {
    name = "tf-bootstrap"
    labels = {
      "managed-by" = "terraform"
    }
    # NO `pod-security.kubernetes.io/enforce: restricted` here. The wait
    # Jobs use `registry.k8s.io/kubectl:v1.31.0` straight from upstream;
    # adding a securityContext to every wait Job (runAsNonRoot + drop
    # ALL caps + seccompProfile RuntimeDefault) just to make the PSA
    # restricted profile happy bloats each Job for no real gain — these
    # pods run a single `kubectl wait` and TTL out in 5 minutes. The
    # alternative explored is documented in infra/TROUBLESHOOTING.md.
  }

  depends_on = [module.eks]
}

resource "kubernetes_service_account_v1" "wait_gate" {
  metadata {
    name      = "wait-gate"
    namespace = kubernetes_namespace_v1.tf_bootstrap.metadata[0].name
  }
}

# Wait Jobs need read-only access to whatever they're waiting on. The
# substrate set: Deployments (most charts expose a Deployment), CRDs
# (ESO publishes SecretStore/ExternalSecret CRDs we gate on Established),
# Pods (statefulset rollouts, fallback for things without a Deployment).
resource "kubernetes_cluster_role_v1" "wait_gate" {
  metadata {
    name = "tf-bootstrap-wait-gate"
  }

  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "statefulsets", "daemonsets"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["apiextensions.k8s.io"]
    resources  = ["customresourcedefinitions"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "wait_gate" {
  metadata {
    name = "tf-bootstrap-wait-gate"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.wait_gate.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.wait_gate.metadata[0].name
    namespace = kubernetes_service_account_v1.wait_gate.metadata[0].namespace
  }
}
