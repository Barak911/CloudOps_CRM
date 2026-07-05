# Runbook: CRM App & Platform Alerts

Linked from the `runbook_url` annotation on the PrometheusRules in
[`k8s/manifests/crm-prometheusrules.yaml`](../../k8s/manifests/crm-prometheusrules.yaml).
One section per alert, in the order you'd triage.

**First 60 seconds, for any page:**

```bash
kubectl get pods -n crm -o wide            # anything not Running/Ready?
kubectl get events -n crm --sort-by=.lastTimestamp | tail -20
kubectl get applications -n argocd         # did a sync just land?
```

---

## CRMAppDown (page)

**Means:** Prometheus has zero healthy scrape targets for the app — every
replica is down or unreachable. The burn-rate alerts are inhibited while this
fires (they'd be noise).

1. `kubectl get pods -n crm -l app=crm-app` — CrashLoop? Pending? Evicted?
2. CrashLoop → `kubectl logs -n crm deploy/crm-stack-crm-app --previous`.
   Most common causes here: bad image digest in `image-state.yaml` (check the
   last `ci(state):` commit), or Mongo auth failure after an uncoordinated
   secret rotation (see [secret-rotation.md](secret-rotation.md)).
3. Pending → `kubectl describe pod` for scheduling events; check Karpenter:
   `kubectl logs -n karpenter deploy/karpenter | tail -30`.
4. Rollback: revert the offending commit on `main`; ArgoCD self-heals to the
   previous digest. `argocd app history crm-stack` shows sync revisions.

## CRMAppErrorBudgetFastBurn (page)

**Means:** 5xx rate is burning the 99% SLO's monthly error budget at ≥14.4x —
budget gone in ~2 days if sustained. Fires on 1h AND 5m windows together, so
it's not a blip.

1. Is it all replicas or one? `kubectl logs` both pods, look for a common
   exception (correlation IDs link log lines to requests).
2. Check MongoDB first — it's the only downstream: `kubectl exec -n crm
   crm-stack-mongodb-0 -- mongosh --eval 'rs.status().members.map(m => m.stateStr)'`.
3. Did a deploy just land? `git log --oneline -3` + `argocd app history` —
   if yes, revert first, diagnose second.

## CRMAppErrorBudgetSlowBurn (ticket)

Same signal at 6x over 6h/30m windows — a simmering problem, not an outage.
Same diagnosis path as FastBurn without the revert-first urgency. Check for
a partial failure mode: one Mongo secondary flapping, sporadic timeouts.

## CRMAppP95LatencyHigh (ticket)

**Means:** p95 over the threshold for 15m. In this stack it's almost always
MongoDB (slow queries / member re-election) or CPU throttling.

1. `kubectl top pods -n crm` — throttling shows as CPU pegged at the limit.
2. Mongo election storm? `rs.status()` — a PRIMARY that changed recently
   means clients paid reconnect latency.
3. If load is organically higher: raise the HPA/replicas, or accept and
   re-baseline the threshold with a note here.

## KubePodCrashLooping (page)

Any pod in `crm` restarting >0 times over 10m.

1. `kubectl logs <pod> --previous` — the previous container has the real error.
2. Hook Jobs (rs-init, es-token) CrashLooping after a sync → almost always
   credentials (rotation done in the wrong order) or a dependency not up yet.
3. OOMKilled → `kubectl describe pod` shows reason; bump the limit in the
   chart values (and re-package the .tgz — CI enforces the match).

## PVCNearFull (ticket)

A PVC in `crm` crossed 85%.

1. Which one: Mongo data or Elasticsearch data.
2. Elasticsearch → old indices are the usual cause: delete or ILM them.
3. MongoDB → check collection sizes; EBS volumes can be expanded online
   (`kubectl patch pvc` with a larger size; the gp3 StorageClass allows
   expansion), then `df -h` inside the pod to confirm.

## MongoDBQuorumLost (page)

**Means:** <2 of 3 members ready — the ReplicaSet cannot elect a PRIMARY;
writes are down. (Backed by kube-state-metrics ready-replica counts, which
track the pods' mongosh-ping readiness probes.)

1. `kubectl get pods -n crm -l app=mongodb -o wide` — where are the members?
   Two on the same drained/failed node means the PDB was bypassed (node
   *failure*, not drain) or disruption protection regressed.
2. `kubectl describe pod` on the not-ready members: volume attach errors
   (EBS stuck detaching from a terminated node is the classic) vs scheduling.
3. Once 2 members are Ready, quorum self-restores — verify with `rs.status()`.
4. Post-incident: confirm the PDB (`kubectl get pdb -n crm`) and the
   `karpenter.sh/do-not-disrupt` annotation are still in place.

## MongoDBMemberDown (ticket)

2/3 ready — quorum holds, redundancy doesn't. Same diagnosis as QuorumLost
at ticket urgency: fix it before the *second* failure turns it into a page.

---

**Escalation:** single-operator deployment — there is no tier 2. If a page
fires and the fix isn't obvious in 30 minutes, the pragmatic move is
`terraform apply`-from-scratch (documented ~25 min to green) with the data
caveat: no backups (see hardening table) — which is itself the argument for
Velero in the table.
