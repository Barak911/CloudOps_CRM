terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    # gavinbunney/kubectl applies raw YAML without server-side validation at
    # plan time. The hashicorp/kubernetes provider's kubernetes_manifest does
    # server-side dry-run during plan — which fails when the cluster doesn't
    # exist yet on the very first apply. kubectl_manifest defers that to
    # apply time and is the canonical workaround for the App-of-Apps
    # bootstrap pattern.
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
