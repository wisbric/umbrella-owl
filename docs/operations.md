# Operations Runbook

## Deploy / Upgrade

### Prerequisites

- Kubernetes 1.27+
- Ingress controller (`nginx`)
- Helm 3.12+
- DNS/TLS for your chosen hostnames

### Lab Install

```bash
helm dep update .
helm upgrade --install owl . \
  -n owl --create-namespace \
  -f values.lab.yaml \
  -f values.lab-secrets.yaml
```

### Upgrade

```bash
helm dep update .
helm upgrade owl . \
  -n owl \
  -f values.lab.yaml \
  -f values.lab-secrets.yaml
```

## Post-Deploy Verification

```bash
kubectl get pods -n owl
kubectl get ingress -n owl

# Owlstack API status
kubectl port-forward svc/owl-owlstack 8080:8080 -n owl &
curl -s http://localhost:8080/api/v1/status | jq .

# Keep websocket route should exist in ingress rules
kubectl describe ingress owl-keep-backend -n owl
```

## Backup & Restore

### Backups

`templates/backup-cronjob.yaml` creates a CronJob (`owl-backup`) when `backup.enabled=true`.

```bash
kubectl get cronjob -n owl
kubectl get jobs -n owl -l app.kubernetes.io/component=backup
kubectl logs -n owl job/<job-name>

# manual backup
kubectl create job --from=cronjob/owl-backup manual-backup-$(date +%s) -n owl
```

### Restore (single database example)

```bash
# Scale apps down first (example)
kubectl scale deploy/owl-owlstack-api --replicas=0 -n owl
kubectl scale deploy/owl-owlstack-worker --replicas=0 -n owl

kubectl port-forward svc/owl-postgresql 5432:5432 -n owl &
PGPASSWORD=<postgres-password> psql -h localhost -U postgres -c "DROP DATABASE nightowl;"
PGPASSWORD=<postgres-password> psql -h localhost -U postgres -c "CREATE DATABASE nightowl OWNER nightowl;"
PGPASSWORD=<postgres-password> pg_restore -h localhost -U postgres -d nightowl /path/to/nightowl.dump

kubectl scale deploy/owl-owlstack-api --replicas=1 -n owl
kubectl scale deploy/owl-owlstack-worker --replicas=1 -n owl
```

## Incident Troubleshooting

### Keep login loop or repeated 401/403 after SSO

Check all three components together:

1. oauth2-proxy is healthy:
   `kubectl logs deploy/owl-keep-oauth2-proxy -n owl --tail=200`
2. Keep backend env has oauth2-proxy mode:
   `kubectl get deploy owl-keep-backend -n owl -o yaml | rg "AUTH_TYPE|KEEP_OAUTH2_PROXY"`
3. Ingress header forwarding for `/backend/*` exists:
   `kubectl describe ingress owl-keep-backend -n owl`

### Keep websocket failures in browser (`/websocket/app/...`)

1. Confirm ingress path routes `/websocket` to websocket service:
   `kubectl describe ingress owl-keep-backend -n owl`
2. Confirm websocket pod logs show connection attempts:
   `kubectl logs deploy/owl-keep-websocket -n owl --tail=200`
3. Confirm frontend uses same public hostname as ingress TLS cert.

### Vector alerts not appearing in Keep

1. Check Vector pod logs:
   `kubectl logs -n owl -l app.kubernetes.io/name=vector --tail=200`
2. Verify sink URL and API key env in `values.lab.yaml`
3. Verify `KEEP_API_KEY` exists in `keep-secrets`

### Keep alerts present but not visible in NightOwl

1. Check Owlstack API logs for webhook auth tenant:
   `kubectl logs deploy/owl-owlstack-api -n owl --tail=300 | rg "webhooks/keep|authenticated via API key"`
2. Confirm webhook requests authenticate to the expected tenant slug (for lab: `acme`).
3. Confirm Vector `NIGHTOWL_API_KEY` reads from `owl-owlstack` key `OWLSTACK_WEBHOOK_KEY`.
4. Confirm Owlstack worker has `OWLSTACK_WEBHOOK_TENANT` set to the same tenant slug.

### Keep -> Owlstack webhook not creating incidents

1. Check Owlstack API logs:
   `kubectl logs deploy/owl-owlstack-api -n owl --tail=300 | rg webhook`
2. Verify Keep workflow target URL:
   `http://owl-owlstack:8080/api/v1/webhooks/keep`
3. Replay a webhook payload against Owlstack and inspect response.

### Outline integration issues

1. Validate Outline pod health:
   `kubectl get pods -l app.kubernetes.io/name=outline -n owl`
2. Validate Owlstack has `outlineUrl` and API token values
3. Ticket document search/link should fail gracefully if Outline is unavailable

### Outline API token bootstrap (first-login flow)

The chart now uses a fail-soft + retry strategy:

1. Hook Job (`owl-outline-setup`) runs on install/upgrade and exits successfully if no Outline admin exists yet.
2. Retry CronJob (`owl-outline-setup-retry`) runs on schedule and applies setup SQL idempotently.
3. After first OIDC login creates an Outline admin user, the next CronJob run inserts/ensures the API token automatically.

Verification:

```bash
# Check one-shot hook result (non-blocking)
kubectl get jobs -n owl | rg outline-setup

# Check retry CronJob is present and scheduled
kubectl get cronjob owl-outline-setup-retry -n owl

# Trigger immediate retry run (optional)
kubectl create job --from=cronjob/owl-outline-setup-retry \
  manual-outline-setup-$(date +%s) -n owl

# Inspect retry logs
kubectl logs -n owl job/<manual-job-name>
```

## Common Ops Tasks

### Restart Owlstack after new images are pushed

```bash
kubectl rollout restart deployment/owl-owlstack-api -n owl
kubectl rollout restart deployment/owl-owlstack-worker -n owl
kubectl rollout restart deployment/owl-owlstack-frontend -n owl
```

### Enable Network Policies

Set:

```yaml
networkPolicies:
  enabled: true
```

Then deploy and verify pod-to-pod traffic for critical flows (Owlstack <-> DB/Redis, Keep routes, Outline OIDC).

## Security Checklist

- [ ] Real secrets are not committed
- [ ] `networkPolicies.enabled=true` in non-lab environments
- [ ] TLS enabled for public endpoints
- [ ] Default/generated passwords rotated
- [ ] Image tags pinned (avoid `main` in production)
