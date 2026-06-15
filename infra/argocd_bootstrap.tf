# The three chicken-and-egg manifests that break the GitOps bootstrap cycle.
#
# 1. SecretStore binding         — ExternalSecrets Operator needs to know
#                                  how to reach AWS Secrets Manager BEFORE
#                                  any ExternalSecret in the repo can sync.
# 2. Repo-credential ExternalSecret — ArgoCD needs a credential to read the
#                                  Git repo. Conceptually that credential
#                                  comes from Secrets Manager via ESO — but
#                                  the manifest that describes it lives
#                                  inside the very repo we're trying to read.
#                                  This is a no-op for a public repo today,
#                                  but the pattern is in place for the day
#                                  the repo goes private.
# 3. Root App-of-Apps             — points ArgoCD at k8s/argocd/apps/ and
#                                  hands the rest of the platform over to
#                                  GitOps reconciliation.
#
# Everything below is applied at terraform apply time. Once these three
# manifests exist in the cluster, ArgoCD is self-sufficient: adding a service
# means a commit, not a kubectl apply.

# -----------------------------------------------------------------------------
# crm namespace — needs to exist for the SA + SecretStore. The crm-stack
# Application also targets this namespace; ArgoCD's CreateNamespace=true
# would handle it later, but ESO needs the namespace before it tries to
# reconcile any ExternalSecret targeted there.
# -----------------------------------------------------------------------------

resource "kubectl_manifest" "crm_namespace" {
  yaml_body = <<-YAML
    apiVersion: v1
    kind: Namespace
    metadata:
      name: ${var.app_namespace}
  YAML

  depends_on = [module.eks]
}

# -----------------------------------------------------------------------------
# 1. Secret-store binding
#    ServiceAccount (IRSA-annotated) + SecretStore that points ESO at
#    AWS Secrets Manager. Namespace-scoped — matches the namespace where the
#    workload ExternalSecrets live.
# -----------------------------------------------------------------------------

resource "kubectl_manifest" "external_secrets_sa" {
  yaml_body = <<-YAML
    apiVersion: v1
    kind: ServiceAccount
    metadata:
      name: external-secrets-sa
      namespace: ${var.app_namespace}
      annotations:
        eks.amazonaws.com/role-arn: ${aws_iam_role.external_secrets.arn}
  YAML

  depends_on = [
    kubectl_manifest.crm_namespace,
    aws_iam_role.external_secrets,
  ]
}

resource "kubectl_manifest" "aws_secrets_manager_store" {
  # validate_schema=false bypasses the provider's client-side cluster
  # discovery, which gets cached on first use and doesn't see CRDs added
  # later in the same plan/apply (the SecretStore CRD comes from the
  # external-secrets helm release earlier in the graph). Server-side apply
  # to the API still validates correctly.
  validate_schema = false

  yaml_body = <<-YAML
    apiVersion: external-secrets.io/v1beta1
    kind: SecretStore
    metadata:
      name: aws-secrets-manager
      namespace: ${var.app_namespace}
    spec:
      provider:
        aws:
          service: SecretsManager
          region: ${var.aws_region}
          auth:
            jwt:
              serviceAccountRef:
                name: external-secrets-sa
  YAML

  # The CRD-Established wait that gates this resource lives in
  # kubernetes_job_v1.external_secrets_ready (infra/helm_releases.tf).
  # It runs in-cluster via `kubectl wait --for=condition=Established`,
  # not on the terraform host — see infra/wait_gates.tf for rationale.
  depends_on = [
    kubernetes_job_v1.external_secrets_ready,
    kubectl_manifest.external_secrets_sa,
  ]
}

# -----------------------------------------------------------------------------
# 2. Repo-credential ExternalSecret
#    For a PUBLIC GitHub repo, ArgoCD doesn't need credentials and this
#    block is a no-op (commented out). The pattern is sketched here so the
#    day the repo goes private, you create a Secrets Manager entry named
#    "<cluster>/argocd-repo-credentials" with `username` + `password` keys
#    and uncomment.
#
# resource "kubectl_manifest" "argocd_repo_credentials" {
#   yaml_body = <<-YAML
#     apiVersion: external-secrets.io/v1beta1
#     kind: ExternalSecret
#     metadata:
#       name: argocd-repo-credentials
#       namespace: argocd
#     spec:
#       refreshInterval: 1h
#       secretStoreRef:
#         name: aws-secrets-manager
#         kind: ClusterSecretStore
#       target:
#         name: argocd-repo-credentials
#         template:
#           metadata:
#             labels:
#               argocd.argoproj.io/secret-type: repository
#           data:
#             url: https://github.com/Barak911/CloudOps_CRM.git
#             username: '{{ .username }}'
#             password: '{{ .password }}'
#       data:
#         - secretKey: username
#           remoteRef:
#             key: ${var.cluster_name}/argocd-repo-credentials
#             property: username
#         - secretKey: password
#           remoteRef:
#             key: ${var.cluster_name}/argocd-repo-credentials
#             property: password
#   YAML
# }
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# 3. Root App-of-Apps
#    Applied from the same YAML committed to git, so the in-cluster object
#    and the file on disk are identical. ArgoCD's own selfHeal will keep it
#    that way; deleting it is the only way out (clean teardown).
# -----------------------------------------------------------------------------

resource "kubectl_manifest" "argocd_root_app" {
  yaml_body = file("${path.module}/../k8s/argocd/root-app.yaml")

  # Gate on the ArgoCD wait Job (argocd-server Deployment Available), not
  # on helm_release.argocd directly — helm_release returns as soon as
  # apply happens; the wait Job is what guarantees argocd-server is up
  # so the Application CR is admitted.
  depends_on = [
    kubernetes_job_v1.argocd_ready,
    kubectl_manifest.aws_secrets_manager_store,
  ]
}
