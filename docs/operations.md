# Operations Runbook

## Deploying Owlstack

### Prerequisites

- Kubernetes 1.27+ cluster with:
  - `nginx` ingress controller
  - `longhorn` storage class (or equivalent)
  - `cert-manager` for TLS (optional, lab uses self-signed)
- Helm 3.12+
- DNS entries for `*.devops.lab` (or your domain)
- GHCR image pull secret (`ghcr-credentials`)

### Install

```bash
# Add subchart repos
helm repo add keephq https://keephq.github.io/helm-charts
helm repo add lrstanley https://helm.liam.sh
helm repo add derwitt https://charts.derwitt.dev

# Generate secrets (first time only)
cd deploy && bash apply-secrets.sh

# Install
helm dep update .
helm install owl . \
  -n owl --create-namespace \
  -f values.lab.yaml \
  -f values.lab-secrets.yaml
```

### Post-install verification

```bash
# All pods running
kubectl get pods -n owl

# Check owlstack API health
kubectl port-forward svc/owl-owlstack 8080:8080 -n owl &
curl -s localhost:8080/api/v1/status | jq .

# Check Keycloak realm
curl -s https://keycloak.devops.lab/realms/owls/.well-known/openid-configuration | jq .issuer
```

### Upgrade

```bash
helm dep update .
helm upgrade owl . \
  -n owl \
  -f values.lab.yaml \
  -f values.lab-secrets.yaml
```

---

## Upgrading Components

### Owlstack (NightOwl + TicketOwl)

1. Build and push new images:
   ```bash
   cd /path/to/owlstack
   docker build -t ghcr.io/wisbric/owlstack:main .
   docker push ghcr.io/wisbric/owlstack:main
   cd web && docker build -t ghcr.io/wisbric/owlstack-web:main .
   docker push ghcr.io/wisbric/owlstack-web:main
   ```
2. Restart deployments (lab uses `pullPolicy: Always`):
   ```bash
   kubectl rollout restart deployment/owl-owlstack-api -n owl
   kubectl rollout restart deployment/owl-owlstack-worker -n owl
   kubectl rollout restart deployment/owl-owlstack-frontend -n owl
   ```
3. Migrations run automatically on container startup.
4. Rollback: `helm rollback owl <revision> -n owl`

### Keep

1. Update version in `Chart.yaml` dependencies.
2. `helm dep update && helm upgrade owl . -f values.lab.yaml -f values.lab-secrets.yaml`
3. Check Keep changelog for breaking changes.

### Outline

1. Update version in `Chart.yaml` dependencies.
2. `helm dep update && helm upgrade`
3. Outline runs its own migrations on startup.

### Keycloak

1. Update version in `Chart.yaml`.
2. **Backup the realm first** — export via Keycloak admin console.
3. `helm dep update && helm upgrade`
4. Test SSO for all apps after upgrade.

### PostgreSQL (minor)

1. Update image tag in values.
2. `helm upgrade` — minor versions are backward compatible.

### PostgreSQL (major)

1. Run backup CronJob manually: `kubectl create job --from=cronjob/owl-backup manual-pre-upgrade -n owl`
2. Scale down all apps: `kubectl scale deploy --all --replicas=0 -n owl`
3. Upgrade PostgreSQL (dump/restore or in-place upgrade).
4. Scale apps back up.

---

## Backup & Recovery

### Automated backups

Daily at 2 AM via CronJob (`owl-backup`). Dumps all databases (nightowl, keycloak, keep, outline) in `pg_dump -Fc` format to a PVC.

```bash
# Check recent backups
kubectl exec -n owl deploy/owl-postgresql -- ls -la /backups/

# Trigger manual backup
kubectl create job --from=cronjob/owl-backup manual-backup-$(date +%s) -n owl
```

### Restore procedure

```bash
# Scale down apps
kubectl scale deploy --all --replicas=0 -n owl

# Port-forward to PostgreSQL
kubectl port-forward svc/owl-postgresql 5432:5432 -n owl &

# Drop and recreate database
PGPASSWORD=<postgres-pw> psql -h localhost -U postgres -c "DROP DATABASE nightowl;"
PGPASSWORD=<postgres-pw> psql -h localhost -U postgres -c "CREATE DATABASE nightowl OWNER nightowl;"

# Restore from backup
PGPASSWORD=<postgres-pw> pg_restore -h localhost -U postgres -d nightowl /path/to/nightowl.dump

# Scale apps back up
kubectl scale deploy --all --replicas=1 -n owl
```

---

## Incident Response (Meta)

### Keep stops receiving alerts

1. Check Keep backend logs: `kubectl logs deploy/owl-keep-backend -n owl`
2. Verify Keep database connection: check `DATABASE_CONNECTION_STRING` secret.
3. Verify Keep's webhook providers are configured (Keep UI > Providers).
4. Test manually: send a test alert via curl to Keep's API.

### Owlstack-Keep webhook broken

1. Check owlstack API logs for webhook errors: `kubectl logs deploy/owl-owlstack-api -n owl | grep webhook`
2. Verify the Keep workflow is configured to POST to `http://owl-owlstack:8080/api/v1/webhooks/keep`.
3. Test manually:
   ```bash
   kubectl port-forward svc/owl-owlstack 8080:8080 -n owl &
   curl -X POST localhost:8080/api/v1/webhooks/keep \
     -H "Content-Type: application/json" \
     -H "X-API-Key: <api-key>" \
     -d '{"id":"test","name":"Test Alert","status":"firing","severity":"warning"}'
   ```

### Outline connection broken

1. Owlstack continues to function — runbook search fails gracefully (returns empty results).
2. Check Outline pod: `kubectl get pods -l app.kubernetes.io/name=outline -n owl`
3. Check Outline logs: `kubectl logs deploy/owl-outline -n owl`
4. Verify Outline URL and API token in owlstack config.

### Keycloak SSO down

1. Local admin login is always available as break-glass: `POST /auth/local` with username `admin`.
2. Check Keycloak pod: `kubectl get pods -l app.kubernetes.io/name=keycloak -n owl`
3. Check Keycloak logs: `kubectl logs deploy/owl-keycloak -n owl`
4. Verify `owls` realm exists: `curl https://keycloak.devops.lab/realms/owls`
5. If realm missing: delete and reinstall Helm release (realm import runs on post-install).

### PostgreSQL connectivity issues

1. Check PostgreSQL pod: `kubectl get pods -l app.kubernetes.io/name=postgresql -n owl`
2. Check PVC: `kubectl get pvc -l app.kubernetes.io/name=postgresql -n owl`
3. Verify connection from owlstack: `kubectl exec deploy/owl-owlstack-api -n owl -- pg_isready -h owl-postgresql`
4. All apps use connection pools and will auto-reconnect once PostgreSQL recovers.

---

## Common Operations

### Adding a monitoring provider to Keep

1. Open Keep UI: `https://keep.devops.lab`
2. Navigate to Providers > Add Provider.
3. Configure (e.g., Alertmanager, Datadog, Grafana).
4. Create a workflow to forward alerts to NightOwl:
   - Trigger: alert received
   - Action: POST to `http://owl-owlstack:8080/api/v1/webhooks/keep`

### Creating escalation policies

1. NightOwl UI > Escalation Policies > Create.
2. Define tiers with timeout, notification channels (Slack, Twilio), and target users/rosters.
3. Link to a roster for automatic alert escalation.

### Managing on-call rosters

1. NightOwl UI > Rosters > Create.
2. Add members, set timezone and handoff schedule.
3. Use overrides for temporary coverage changes.
4. View coverage heatmap at NightOwl UI > Status.

### Creating runbook documents in Outline

1. Open Outline: `https://outline.devops.lab`
2. Create a new document in the appropriate collection.
3. Link to incidents in NightOwl via the incident detail page > Runbook field.

---

## Security Hardening Checklist

- [ ] Enable NetworkPolicies: set `networkPolicies.enabled: true` in values
- [ ] Rotate default passwords generated by `apply-secrets.sh`
- [ ] Use sealed-secrets or external-secrets-operator for GitOps
- [ ] Pin image tags (no `:main` or `:latest` in production)
- [ ] Enable Keycloak brute-force protection
- [ ] Configure RBAC: minimal ServiceAccount permissions
- [ ] Enable Pod Security Standards (restricted profile)
- [ ] Review ingress TLS: ensure all services use valid certificates
