# Runbook: Credential Rotation (MongoDB / Elasticsearch)

**Why this runbook exists:** rotating a password in AWS Secrets Manager alone
**breaks this stack**. Self-hosted databases store their own copy of every user
password. ESO refreshes the k8s Secret (within its `refreshInterval`, 1h) to the
new value — but the database still expects the old one. From that moment:

- The ArgoCD rs-init hook Job auths with the *new* password against a database
  holding the *old* one → CrashLoop (`backoffLimit: 6`) → sync degraded.
- App pods keep working **until their next restart** (creds are injected as env
  vars at pod start), then fail auth cluster-wide. This is the worst kind of
  breakage: delayed, and triggered by an unrelated event (node drain, deploy).

The database is the source of truth for its own passwords. Secrets Manager is a
*distribution* mechanism, not the authority. Rotate **inside the database
first**, then update Secrets Manager, then restart consumers deliberately.

---

## MongoDB — rotating `app_password` (the app user)

```bash
# 1. Get current root creds (needed to auth for the change)
aws secretsmanager get-secret-value \
  --secret-id crm-cluster/mongodb-credentials \
  --query SecretString --output text | jq .

# 2. Generate the new password (alnum only — it lands in a connection URI)
NEW_PASS=$(openssl rand -hex 24)

# 3. Change it INSIDE MongoDB first (via the PRIMARY)
kubectl exec -n crm crm-stack-mongodb-0 -- mongosh admin \
  -u admin -p "$OLD_ROOT_PASS" --quiet --eval \
  "db.getSiblingDB('crm').changeUserPassword('crm_app', '$NEW_PASS')"
# From this moment until step 5 completes, NEW app pods would fail auth —
# existing pods are unaffected (they hold an open, already-authed connection).

# 4. Update Secrets Manager with the same value
aws secretsmanager put-secret-value \
  --secret-id crm-cluster/mongodb-credentials \
  --secret-string "$(jq -n --arg p "$NEW_PASS" \
     '{username:"admin",password:$OLD_ROOT,app_username:"crm_app",app_password:$p}')"

# 5. Force ESO to sync now instead of waiting for the 1h refresh
kubectl annotate externalsecret -n crm mongodb-credentials \
  force-sync=$(date +%s) --overwrite

# 6. Restart consumers so env vars pick up the new value
kubectl rollout restart -n crm deployment/crm-stack-crm-app
kubectl rollout status  -n crm deployment/crm-stack-crm-app
```

## MongoDB — rotating the root password

Same shape, but the change targets `admin`:

```bash
kubectl exec -n crm crm-stack-mongodb-0 -- mongosh admin \
  -u admin -p "$OLD_ROOT_PASS" --quiet --eval \
  "db.changeUserPassword('admin', '$NEW_ROOT_PASS')"
```

Then steps 4–5 as above. The root password is consumed by the rs-init hook Job
(next ArgoCD sync) and the mongo containers' `MONGO_INITDB_ROOT_*` env (only
read on **first** initialization of an empty data dir — harmless for running
members). No app restart needed.

**Order matters:** database first, Secrets Manager second. If you invert it and
anything restarts in between, you get the CrashLoop described above. If that
happens: put the OLD value back in Secrets Manager, force-sync ESO, let the
Job retry — then redo the rotation in the right order.

## Elasticsearch — rotating the `elastic` password

Same pattern, ES API instead of mongosh:

```bash
kubectl exec -n crm crm-stack-elasticsearch-master-0 -- \
  curl -sk -u "elastic:$OLD_PASS" -X POST \
  "https://localhost:9200/_security/user/elastic/_password" \
  -H 'Content-Type: application/json' \
  -d "{\"password\":\"$NEW_PASS\"}"
```

Then update `crm-cluster/elasticsearch-credentials` in Secrets Manager,
force-sync the ExternalSecret, and restart Kibana + Fluentd so their env/config
pick up the new value.

## Production notes

- This manual coordination is exactly what an AWS Secrets Manager **rotation
  Lambda** automates (the multi-step `createSecret → setSecret → testSecret →
  finishSecret` state machine exists because of this database-first problem).
  That's the listed production recommendation in the README hardening table.
- A restart-on-secret-change controller (e.g. stakater/Reloader) removes the
  "works until next restart" trap by making consumers restart *immediately*
  when ESO refreshes the Secret — turning a delayed surprise into a visible,
  attributable event.
