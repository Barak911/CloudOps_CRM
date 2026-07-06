# Substrate controllers installed by Terraform via the helm provider.
#
# These five releases sit on the same lifecycle as the cluster itself:
# nothing else can schedule until they're up, and they can't be GitOps-managed
# yet because the GitOps controller IS one of them.
#
# Pattern: `wait = false` + `kubernetes_job` running `kubectl wait` per
# release. See infra/wait_gates.tf for the design rationale (short version:
# `wait = true` holds the terraform state lock for 15+ minutes across the
# five releases; moving the wait into in-cluster Jobs takes the lock-held
# time per release from minutes to seconds).
#
# Downstream resources (kubectl_manifest for the ClusterIssuer, SecretStore,
# Karpenter NodePool, root App) depend on the *wait Job*, not on the
# helm_release directly. That dependency chain is what guarantees ordering.

# -----------------------------------------------------------------------------
# Local helper: minimal Job spec for `kubectl wait`. Inlined into each
# kubernetes_job below — Terraform doesn't have proper template functions
# for resource bodies, so duplication is intentional.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Nginx Ingress Controller — substrate. Other helm releases that create
# Ingresses (ArgoCD's server.ingress) need this controller's admission
# webhook to be live, so nginx-ingress comes first.
# -----------------------------------------------------------------------------

resource "helm_release" "nginx_ingress" {
  name             = "nginx-ingress"
  namespace        = "ingress-nginx"
  create_namespace = true

  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  version    = "4.14.3"

  values = [file("${path.module}/../k8s/values/nginx-ingress-values.yaml")]

  wait    = false # the wait Job below holds the readiness gate
  timeout = 120

  depends_on = [module.eks]
}

resource "kubernetes_job_v1" "nginx_ingress_ready" {
  metadata {
    name      = "wait-nginx-ingress"
    namespace = kubernetes_namespace_v1.tf_bootstrap.metadata[0].name
  }

  spec {
    backoff_limit              = 5
    ttl_seconds_after_finished = 300

    template {
      metadata {
        labels = { app = "wait-nginx-ingress" }
      }
      spec {
        service_account_name = kubernetes_service_account_v1.wait_gate.metadata[0].name
        restart_policy       = "OnFailure"
        container {
          name  = "wait"
          image = local.wait_image
          args = [
            "wait",
            "--namespace=ingress-nginx",
            "--for=condition=Available",
            "--timeout=600s",
            "deployment/nginx-ingress-ingress-nginx-controller",
          ]
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "15m"
    update = "15m"
  }

  depends_on = [
    helm_release.nginx_ingress,
    kubernetes_cluster_role_binding_v1.wait_gate,
  ]
}

# -----------------------------------------------------------------------------
# ArgoCD — the GitOps controller. Must wait for nginx_ingress_ready because
# ArgoCD's chart creates an Ingress and the nginx admission webhook will
# reject it until the controller is up.
# -----------------------------------------------------------------------------

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  # Chart 9.5.x = ArgoCD v3.4.x. 7.7.10 ran ArgoCD v2.13 (late 2024) —
  # flagged as version drift in review; v2.13 also breaks on the
  # terminatingReplicas schema gap against newer control planes.
  version = "9.5.20"

  values = [file("${path.module}/../k8s/values/argocd-values.yaml")]

  wait    = false
  timeout = 120

  depends_on = [
    module.eks,
    kubernetes_job_v1.nginx_ingress_ready,
  ]
}

resource "kubernetes_job_v1" "argocd_ready" {
  metadata {
    name      = "wait-argocd"
    namespace = kubernetes_namespace_v1.tf_bootstrap.metadata[0].name
  }

  spec {
    backoff_limit              = 5
    ttl_seconds_after_finished = 300

    template {
      metadata {
        labels = { app = "wait-argocd" }
      }
      spec {
        service_account_name = kubernetes_service_account_v1.wait_gate.metadata[0].name
        restart_policy       = "OnFailure"
        container {
          name  = "wait"
          image = local.wait_image
          # Gate on argocd-server, the single Deployment that the root App
          # CRD application + the application-controller need. The other
          # ArgoCD components (repo-server, redis, applicationset) reconcile
          # in parallel and don't block apply.
          args = [
            "wait",
            "--namespace=argocd",
            "--for=condition=Available",
            "--timeout=600s",
            "deployment/argocd-server",
          ]
        }
      }
    }
  }

  wait_for_completion = true
  timeouts {
    create = "15m"
    update = "15m"
  }

  depends_on = [
    helm_release.argocd,
    kubernetes_cluster_role_binding_v1.wait_gate,
  ]
}

# -----------------------------------------------------------------------------
# ExternalSecrets Operator — provides ClusterSecretStore + ExternalSecret CRDs.
# Downstream SecretStore in argocd_bootstrap.tf gates on the CRD being
# Established, not just the operator Deployment being Ready, because the
# kubectl provider's REST client construction needs the CRD discoverable.
# -----------------------------------------------------------------------------

resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true

  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  version    = "0.10.5"

  set {
    name  = "installCRDs"
    value = "true"
  }

  wait    = false
  timeout = 120

  depends_on = [module.eks]
}

resource "kubernetes_job_v1" "external_secrets_ready" {
  metadata {
    name      = "wait-external-secrets"
    namespace = kubernetes_namespace_v1.tf_bootstrap.metadata[0].name
  }

  spec {
    backoff_limit              = 5
    ttl_seconds_after_finished = 300

    template {
      metadata {
        labels = { app = "wait-external-secrets" }
      }
      spec {
        service_account_name = kubernetes_service_account_v1.wait_gate.metadata[0].name
        restart_policy       = "OnFailure"
        # Two containers run in parallel: one waits for the operator
        # Deployment, the other for the CRDs to be Established.
        container {
          name  = "wait-operator"
          image = local.wait_image
          args = [
            "wait",
            "--namespace=external-secrets",
            "--for=condition=Available",
            "--timeout=600s",
            "deployment/external-secrets",
          ]
        }
        container {
          name  = "wait-crds"
          image = local.wait_image
          args = [
            "wait",
            "--for=condition=Established",
            "--timeout=600s",
            "crd/secretstores.external-secrets.io",
            "crd/externalsecrets.external-secrets.io",
            "crd/clustersecretstores.external-secrets.io",
          ]
        }
        # Same principle as the cert-manager gate: the VALIDATING WEBHOOK is
        # what downstream creation actually waits on. Creating the
        # SecretStore right after CRDs turn Established races the webhook
        # pods — the API server calls validate.secretstore.external-secrets.io
        # and gets "no endpoints available". Caught on the first clean
        # custom-VPC bootstrap; operator+CRDs alone are not enough.
        container {
          name  = "wait-webhook"
          image = local.wait_image
          args = [
            "wait",
            "--namespace=external-secrets",
            "--for=condition=Available",
            "--timeout=600s",
            "deployment/external-secrets-webhook",
          ]
        }
      }
    }
  }

  wait_for_completion = true
  timeouts {
    create = "15m"
    update = "15m"
  }

  depends_on = [
    helm_release.external_secrets,
    kubernetes_cluster_role_binding_v1.wait_gate,
  ]
}

# -----------------------------------------------------------------------------
# cert-manager — gate on the webhook Deployment, not the cert-manager
# Deployment itself. cert-manager-webhook is the one downstream
# ClusterIssuer/Certificate creation actually waits on.
# -----------------------------------------------------------------------------

resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true

  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = "v1.16.1"

  set {
    name  = "crds.enabled"
    value = "true"
  }

  wait    = false
  timeout = 120

  depends_on = [module.eks]
}

resource "kubernetes_job_v1" "cert_manager_ready" {
  metadata {
    name      = "wait-cert-manager"
    namespace = kubernetes_namespace_v1.tf_bootstrap.metadata[0].name
  }

  spec {
    backoff_limit              = 5
    ttl_seconds_after_finished = 300

    template {
      metadata {
        labels = { app = "wait-cert-manager" }
      }
      spec {
        service_account_name = kubernetes_service_account_v1.wait_gate.metadata[0].name
        restart_policy       = "OnFailure"
        # cert-manager has 3 Deployments. The webhook is the gating one;
        # ClusterIssuer creation goes through admission validation and
        # fails until webhook is Available.
        container {
          name  = "wait-webhook"
          image = local.wait_image
          args = [
            "wait",
            "--namespace=cert-manager",
            "--for=condition=Available",
            "--timeout=600s",
            "deployment/cert-manager-webhook",
          ]
        }
      }
    }
  }

  wait_for_completion = true
  timeouts {
    create = "15m"
    update = "15m"
  }

  depends_on = [
    helm_release.cert_manager,
    kubernetes_cluster_role_binding_v1.wait_gate,
  ]
}

resource "kubectl_manifest" "selfsigned_clusterissuer" {
  yaml_body = <<-YAML
    apiVersion: cert-manager.io/v1
    kind: ClusterIssuer
    metadata:
      name: selfsigned-issuer
    spec:
      selfSigned: {}
  YAML

  depends_on = [kubernetes_job_v1.cert_manager_ready]
}

# -----------------------------------------------------------------------------
# Karpenter — burst node autoscaler. See infra/karpenter.tf for the IAM
# + SQS infrastructure it consumes.
# -----------------------------------------------------------------------------

resource "helm_release" "karpenter" {
  name             = "karpenter"
  namespace        = "karpenter"
  create_namespace = true

  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  # Must move in lockstep with cluster_version — each Karpenter minor
  # supports a narrow k8s range (1.1.x tops out at k8s 1.31). 1.12.x
  # covers k8s 1.34; NodePool/EC2NodeClass stay on the v1 API.
  version = "1.12.1"

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.karpenter_controller.arn
  }

  set {
    name  = "settings.clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "settings.interruptionQueue"
    value = aws_sqs_queue.karpenter_interruption.name
  }

  set {
    name  = "controller.resources.requests.cpu"
    value = "200m"
  }

  set {
    name  = "controller.resources.requests.memory"
    value = "256Mi"
  }

  set {
    name  = "controller.resources.limits.cpu"
    value = "500m"
  }

  set {
    name  = "controller.resources.limits.memory"
    value = "512Mi"
  }

  wait    = false
  timeout = 120

  depends_on = [
    module.eks,
    aws_iam_role.karpenter_controller,
    aws_iam_role_policy_attachment.karpenter_controller,
    aws_iam_instance_profile.karpenter_node,
    aws_eks_access_entry.karpenter_node,
  ]
}

resource "kubernetes_job_v1" "karpenter_ready" {
  metadata {
    name      = "wait-karpenter"
    namespace = kubernetes_namespace_v1.tf_bootstrap.metadata[0].name
  }

  spec {
    backoff_limit              = 5
    ttl_seconds_after_finished = 300

    template {
      metadata {
        labels = { app = "wait-karpenter" }
      }
      spec {
        service_account_name = kubernetes_service_account_v1.wait_gate.metadata[0].name
        restart_policy       = "OnFailure"
        # Karpenter publishes its CRDs (EC2NodeClass, NodePool); gate on
        # both the controller Deployment AND those CRDs being Established
        # so the downstream kubectl_manifest doesn't fail on REST client init.
        container {
          name  = "wait-deployment"
          image = local.wait_image
          args = [
            "wait",
            "--namespace=karpenter",
            "--for=condition=Available",
            "--timeout=600s",
            "deployment/karpenter",
          ]
        }
        container {
          name  = "wait-crds"
          image = local.wait_image
          args = [
            "wait",
            "--for=condition=Established",
            "--timeout=600s",
            "crd/ec2nodeclasses.karpenter.k8s.aws",
            "crd/nodepools.karpenter.sh",
          ]
        }
      }
    }
  }

  wait_for_completion = true
  timeouts {
    create = "15m"
    update = "15m"
  }

  depends_on = [
    helm_release.karpenter,
    kubernetes_cluster_role_binding_v1.wait_gate,
  ]
}

# Karpenter EC2NodeClass + NodePool — values come from terraform.
resource "kubectl_manifest" "karpenter_ec2nodeclass" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: default
    spec:
      amiFamily: AL2023
      amiSelectorTerms:
        - alias: al2023@latest
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${var.cluster_name}
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${var.cluster_name}
      instanceProfile: ${aws_iam_instance_profile.karpenter_node.name}
      blockDeviceMappings:
        - deviceName: /dev/xvda
          ebs:
            volumeType: gp3
            volumeSize: 50Gi
            encrypted: true
            deleteOnTermination: true
      metadataOptions:
        httpEndpoint: enabled
        httpProtocolIPv6: disabled
        httpPutResponseHopLimit: 1
        httpTokens: required
      tags:
        project: CloudOps_CRM
        karpenter.sh/discovery: ${var.cluster_name}
  YAML

  depends_on = [kubernetes_job_v1.karpenter_ready]
}

resource "kubectl_manifest" "karpenter_nodepool" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: default
    spec:
      template:
        metadata:
          labels:
            nodepool: karpenter-default
        spec:
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: default
          requirements:
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["spot", "on-demand"]
            - key: kubernetes.io/arch
              operator: In
              values: ["amd64"]
            - key: kubernetes.io/os
              operator: In
              values: ["linux"]
            - key: karpenter.k8s.aws/instance-category
              operator: In
              values: ["t", "m", "c"]
            - key: karpenter.k8s.aws/instance-generation
              operator: Gt
              values: ["2"]
            - key: karpenter.k8s.aws/instance-size
              operator: In
              values: ["medium", "large", "xlarge"]
          expireAfter: 168h
          terminationGracePeriod: 1h
      disruption:
        consolidationPolicy: WhenEmptyOrUnderutilized
        consolidateAfter: 1m
      limits:
        cpu: "32"
        memory: 64Gi
  YAML

  depends_on = [kubectl_manifest.karpenter_ec2nodeclass]
}
