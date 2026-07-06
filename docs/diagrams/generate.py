#!/usr/bin/env python3
"""Architecture diagrams-as-code for CloudOps_CRM.

Regenerate after architecture changes:
    python3 -m venv .diagrams-venv && ./.diagrams-venv/bin/pip install diagrams
    ./.diagrams-venv/bin/python docs/diagrams/generate.py
Requires graphviz (`brew install graphviz`). Outputs PNGs next to this file.
"""

import os

from diagrams import Cluster, Diagram, Edge
from diagrams.aws.compute import EC2, EKS
from diagrams.aws.database import Dynamodb
from diagrams.aws.integration import SQS, Eventbridge
from diagrams.aws.management import CloudwatchAlarm
from diagrams.aws.network import ELB, InternetGateway, NATGateway
from diagrams.aws.security import IAM, SecretsManager
from diagrams.aws.storage import S3
from diagrams.elastic.elasticsearch import Elasticsearch, Kibana
from diagrams.k8s.compute import Deployment, Pod, StatefulSet
from diagrams.k8s.network import Ingress, NetworkPolicy
from diagrams.k8s.podconfig import Secret
from diagrams.onprem.ci import GithubActions
from diagrams.onprem.client import Users
from diagrams.onprem.container import Docker
from diagrams.onprem.database import Mongodb
from diagrams.onprem.gitops import Argocd
from diagrams.onprem.aggregator import Fluentd
from diagrams.onprem.monitoring import Grafana, Prometheus
from diagrams.onprem.vcs import Github

OUT = os.path.dirname(os.path.abspath(__file__))
GRAPH_ATTR = {"fontsize": "13", "pad": "0.4"}


def out(name: str) -> str:
    return os.path.join(OUT, name)


# ---------------------------------------------------------------------------
# 01 — AWS infrastructure (Terraform-provisioned, custom VPC)
# ---------------------------------------------------------------------------
with Diagram(
    "CloudOps CRM — AWS Infrastructure (Terraform-provisioned)",
    filename=out("01-aws-infrastructure"),
    show=False,
    graph_attr=GRAPH_ATTR,
):
    with Cluster("Terraform remote state"):
        tf_state = S3("S3 (versioned, SSE,\nnative locking)")

    users = Users("Engineers / clients")
    users - Edge(style="dotted", label="terraform") - tf_state

    with Cluster("AWS account · us-east-1"):
        ecr = Docker("ECR crm-app\n(immutable tags)")
        sqs = SQS("Karpenter\ninterruption queue")
        events = Eventbridge("spot / rebalance\n/ health events")
        secrets = SecretsManager("Secrets Manager\nmongodb / elasticsearch")
        irsa = IAM("IRSA roles\n(ESO · Karpenter · EBS CSI)")

        with Cluster("VPC 10.0.0.0/16 (secure-by-default path)"):
            igw = InternetGateway("Internet Gateway")

            with Cluster("Public subnets · 3 AZ"):
                nlb = ELB("NLB (nginx-ingress)")
                nat = NATGateway("NAT (single —\naccepted tradeoff)")

            with Cluster("Private subnets · 3 AZ"):
                eks = EKS("EKS 1.34\ncontrol plane\n(addons pinned)")

                with Cluster("Managed node group · t3a.medium ×3"):
                    system_nodes = EC2("baseline nodes\n(system + stateful)")

                with Cluster("Karpenter-provisioned · spot-first"):
                    burst = EC2("burst nodes\n(AL2023, IMDSv2,\nencrypted gp3)")

        users >> Edge(label="HTTPS") >> igw >> nlb
        nat >> Edge(style="dashed", label="egress: image pulls,\nAWS APIs") >> igw
        eks >> Edge(label="provisions JIT") >> burst
        events >> sqs >> Edge(label="drain warning") >> eks
        system_nodes - Edge(style="dotted") - eks
        irsa >> Edge(label="AssumeRole") >> secrets
        burst - Edge(style="dotted", label="pull @sha256:") - ecr

# ---------------------------------------------------------------------------
# 02 — Kubernetes topology (what ArgoCD reconciles)
# ---------------------------------------------------------------------------
with Diagram(
    "CloudOps CRM — Kubernetes Topology",
    filename=out("02-kubernetes-topology"),
    show=False,
    graph_attr=GRAPH_ATTR,
):
    with Cluster("EKS cluster"):
        with Cluster("argocd"):
            argo = Argocd("app-of-apps\n(3 child apps)")

        with Cluster("ingress-nginx (Terraform substrate)"):
            ingress = Ingress("nginx → NLB")

        with Cluster("crm — default-deny NetworkPolicies (enforced)"):
            netpol = NetworkPolicy("14 policies")
            app = Deployment("crm-app ×2\n(PDB minAvailable:1)")
            mongo = StatefulSet("MongoDB ReplicaSet ×3\nPDB maxUnavailable:1\nkarpenter do-not-disrupt")
            es = Elasticsearch("elasticsearch ×1\n(logging SPOF — accepted)")
            kib = Kibana("kibana")
            fluentd = Fluentd("fluentd ×3")

        with Cluster("monitoring"):
            prom = Prometheus("kube-prometheus-stack\nSLO burn-rate rules")
            graf = Grafana("dashboards")
            alerts = CloudwatchAlarm("Alertmanager\nseverity routes + inhibit")

        with Cluster("external-secrets"):
            eso = Secret("ESO → k8s Secrets\n(IRSA, no static creds)")

    argo >> Edge(label="sync") >> [app, mongo, es, kib, fluentd, prom]
    ingress >> app >> mongo
    fluentd >> es >> kib
    prom >> alerts
    prom - Edge(style="dotted") - graf
    netpol - Edge(style="dotted") - app
    eso - Edge(style="dotted", label="materializes creds") - mongo

# ---------------------------------------------------------------------------
# 03 — Request & telemetry flow
# ---------------------------------------------------------------------------
with Diagram(
    "CloudOps CRM — Request and Telemetry Flow",
    filename=out("03-request-flow"),
    show=False,
    graph_attr=GRAPH_ATTR,
):
    client = Users("Client")
    lb = ELB("NLB")
    ing = Ingress("nginx-ingress\n(TLS: cert-manager\nself-signed)")
    api = Deployment("crm-app (Flask)\n/metrics · correlation IDs\nno str(e) leakage")
    db = Mongodb("MongoDB rs0\nmulti-host URI\nreplicaSet=rs0")

    client >> Edge(label="HTTPS") >> lb >> ing >> api >> db

    with Cluster("Telemetry"):
        prom = Prometheus("Prometheus\nRED + burn-rate")
        graf = Grafana("Grafana")
        fluentd = Fluentd("Fluentd DaemonSet")
        es = Elasticsearch("Elasticsearch")
        kib = Kibana("Kibana")

    api >> Edge(style="dashed", label="scrape /metrics") >> prom >> graf
    api >> Edge(style="dashed", label="stdout JSON logs") >> fluentd >> es >> kib

# ---------------------------------------------------------------------------
# 04 — GitOps delivery (CI has zero cluster access)
# ---------------------------------------------------------------------------
with Diagram(
    "CloudOps CRM — GitOps Delivery",
    filename=out("04-gitops-delivery"),
    show=False,
    graph_attr=GRAPH_ATTR,
):
    dev = Users("Developer")
    repo = Github("Barak911/CloudOps_CRM\n(main = desired state)")

    with Cluster("GitHub Actions — OIDC, no static keys"):
        ci = GithubActions("CI: pytest · pip-audit\nTrivy · E2E · kubeconform\nchart-drift check")
        sign = GithubActions("cosign keyless sign\n+ SPDX SBOM attest\n(only what THIS run built)")

    ecr = Docker("ECR\nimmutable tags,\nresolved to @sha256:")
    state = Github("image-state.yaml\n(bot commit, [skip ci])")

    with Cluster("EKS"):
        argo = Argocd("ArgoCD\nauto-sync + selfHeal")
        workloads = Pod("crm-stack\n(umbrella chart)")

    dev >> Edge(label="push / PR") >> repo >> ci >> sign >> ecr
    sign >> Edge(label="tag + digest") >> state
    state - Edge(style="dotted") - repo
    repo >> Edge(label="watched") >> argo >> workloads
    ecr >> Edge(style="dashed", label="pull @sha256:") >> workloads
    ci >> Edge(style="bold", color="red", label="NO cluster access\n(ECR-only IAM role)") >> ecr

print("Generated 4 diagrams in", OUT)
