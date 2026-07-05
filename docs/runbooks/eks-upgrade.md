# Runbook: EKS Version Upgrade

This cluster is destroy-and-rebuild (no in-place upgrade has ever been
required), which makes version bumps simpler than production — but the *order
of decisions* is the same one an in-place upgrade needs, so it's written out
fully.

## Why this matters

- **Extended support bills ~6x** for the control plane the day standard
  support ends. This repo sat on 1.31 past its Nov-2025 standard-support
  cutoff — that's the mistake this runbook prevents recurring.
- Karpenter, addons, and the kubectl wait-image all have **narrow k8s
  compatibility windows**; bumping `cluster_version` alone produces a cluster
  that fails bootstrap in non-obvious ways (Karpenter controller crash-loop is
  the usual first symptom).

## Procedure

### 1. Pick the target version — from the live API, never from memory

```bash
aws eks describe-cluster-versions \
  --query 'clusterVersions[?versionStatus==`STANDARD_SUPPORT`].{v:clusterVersion,end:endOfStandardSupportDate}' \
  --output table
```

Pick a version with **6+ months of standard support left** (not the newest —
one behind the newest usually has the best ecosystem compatibility).

### 2. Collect the compatible component versions (all queried live)

```bash
# Addon defaults for the target version:
for a in vpc-cni coredns kube-proxy aws-ebs-csi-driver; do
  aws eks describe-addon-versions --kubernetes-version <TARGET> --addon-name $a \
    --query 'addons[0].addonVersions[?compatibilities[0].defaultVersion==`true`].addonVersion|[0]' \
    --output text
done
```

- **Karpenter**: check the compatibility matrix
  (karpenter.sh/docs/upgrading/compatibility) — each minor supports a narrow
  k8s range. Update the chart `version` in `infra/helm_releases.tf`; diff the
  upstream reference IAM policy against `infra/karpenter.tf` (actions get
  added between minors — e.g. `ec2:DescribeCapacityReservations` in 1.3).
- **kubectl wait image** (`infra/wait_gates.tf`): match the control-plane
  minor (`registry.k8s.io/kubectl:v<TARGET>.x`).
- **alpine/k8s** hook image in `k8s/crm-stack/values.yaml`: same rule.

### 3. Update, in one commit

| File | What |
|---|---|
| `infra/variables.tf` | `cluster_version` default |
| `infra/eks.tf` | 3 addon `addon_version` pins |
| `infra/ebs-csi-driver.tf` | EBS CSI `addon_version` |
| `infra/helm_releases.tf` | Karpenter chart version |
| `infra/karpenter.tf` | IAM policy delta if any |
| `infra/wait_gates.tf` | `wait_image` |
| `k8s/crm-stack/values.yaml` | `alpine/k8s` hook image |
| `README.md` / `infra/README.md` / `infra/ARCHITECTURE.md` | version references |

### 4. Validate

Fresh-account bootstrap (`terraform apply` → bootstrap workflow) is the test.
Watch for, in order: addons reaching ACTIVE, node group Ready, Karpenter
controller not crash-looping, wait-Jobs completing, ArgoCD apps Healthy.

For a true in-place upgrade (not needed here yet): control plane first, then
addons, then managed node group AMI, then Karpenter's `amiSelectorTerms`
alias — one minor at a time, checking `kubectl get nodes` skew stays within
±2 minors of the control plane throughout.
