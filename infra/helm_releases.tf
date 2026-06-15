# Substrate controllers installed by Terraform via the helm provider.
#
# These four releases sit on the same lifecycle as the cluster itself:
# nothing else can schedule until they're up, and they can't be GitOps-managed
# yet because the GitOps controller IS one of them. Once they're running,
# Terraform applies the App-of-Apps root (infra/argocd_bootstrap.tf) and
# everything else flows through ArgoCD.
#
# Each release depends on the EKS module and on the managed addons being
# Ready — without CoreDNS, CNI, kube-proxy, helm installs can't pull images
# or resolve services. The addons live inside the module, so depending on
# `module.eks` is sufficient (terraform-aws-modules/eks v20 declares the
# addons as dependents of the cluster).

# -----------------------------------------------------------------------------
# ArgoCD
# -----------------------------------------------------------------------------

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "7.7.10"

  values = [file("${path.module}/../k8s/values/argocd-values.yaml")]

  wait    = true
  timeout = 600

  depends_on = [module.eks]
}

# -----------------------------------------------------------------------------
# ExternalSecrets Operator (binds the cluster to AWS Secrets Manager via IRSA)
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

  wait    = true
  timeout = 300

  depends_on = [module.eks]
}

# -----------------------------------------------------------------------------
# cert-manager (self-signed ClusterIssuer for ingress TLS)
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

  wait    = true
  timeout = 300

  depends_on = [module.eks]
}

# Self-signed ClusterIssuer — applied after cert-manager is up.
resource "kubectl_manifest" "selfsigned_clusterissuer" {
  yaml_body = <<-YAML
    apiVersion: cert-manager.io/v1
    kind: ClusterIssuer
    metadata:
      name: selfsigned-issuer
    spec:
      selfSigned: {}
  YAML

  depends_on = [helm_release.cert_manager]
}

# -----------------------------------------------------------------------------
# Nginx Ingress Controller (substrate — every Application's Ingress depends
# on the IngressClass + the NLB this provisions).
# -----------------------------------------------------------------------------
#
# Was an ArgoCD child app, moved here because the chart's pre-install hook
# (admission-create Job) interacts badly with ArgoCD's PreSync semantics —
# the hook completes successfully in AWS but ArgoCD's view stays stuck on
# "waiting for completion of hook batch/Job/..." forever. Installing via
# terraform's helm provider sidesteps ArgoCD's hook handling entirely,
# which is the right tradeoff anyway: nginx-ingress is platform substrate
# (every other workload depends on it), same category as ArgoCD itself.

resource "helm_release" "nginx_ingress" {
  name             = "nginx-ingress"
  namespace        = "ingress-nginx"
  create_namespace = true

  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  version    = "4.14.3"

  values = [file("${path.module}/../k8s/values/nginx-ingress-values.yaml")]

  wait    = true
  timeout = 600

  depends_on = [module.eks]
}

# -----------------------------------------------------------------------------
# Karpenter (burst node autoscaler — see infra/karpenter.tf for IAM + SQS)
# -----------------------------------------------------------------------------

resource "helm_release" "karpenter" {
  name             = "karpenter"
  namespace        = "karpenter"
  create_namespace = true

  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = "1.1.1"

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

  wait    = true
  timeout = 600

  depends_on = [
    module.eks,
    aws_iam_role.karpenter_controller,
    aws_iam_role_policy_attachment.karpenter_controller,
    aws_iam_instance_profile.karpenter_node,
    aws_eks_access_entry.karpenter_node,
  ]
}

# Karpenter EC2NodeClass + NodePool — applied after Karpenter helm release
# is Ready. envsubst is gone; values come straight from terraform.
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

  depends_on = [helm_release.karpenter]
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
