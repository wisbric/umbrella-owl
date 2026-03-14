# umbrella-owl

Umbrella Helm chart for deploying the Wisbric owl platform as one release.

This repo is deployment/wiring only (Helm values, templates, environment overlays, ops docs).

## Included Components

### Owl Application

| Component | Source | Purpose |
|---|---|---|
| `owlstack` | `file://../owlstack/deploy/helm/owlstack` (local chart dependency in this monorepo) | Unified operations app (incidents, alerts, on-call, ticket orchestration, customer portal) |

### Third-Party Dependencies

| Chart | Purpose | Condition |
|---|---|---|
| `postgresql` (Bitnami) | Shared database | `postgresql.enabled` |
| `redis` (Bitnami) | Cache/queues/sessions | `redis.enabled` |
| `keycloak` (Bitnami) | OIDC IdP | `keycloak.enabled` |
| `zammad` | Ticket backend | `zammad.enabled` |
| `keep` | Alert management UI/API | `keep.enabled` |
| `outline` | Knowledge/docs wiki | `outline.enabled` |
| `garage` | S3-compatible storage for Outline uploads | `garage.enabled` |
| `vector` | Alert/telemetry pipeline (e.g. Vector -> Keep) | `vector.enabled` |

## Platform Architecture

- Owlstack is the core app
- Keep runs behind oauth2-proxy for Keycloak SSO
- Outline uses direct OIDC against Keycloak
- Garage backs Outline file uploads
- Vector can push alert events into Keep
- Optional backup CronJob and NetworkPolicies are templated in this chart

## Quick Start

```bash
# From umbrella-owl/
helm dep update .

# Lab install
helm upgrade --install owl . \
  --namespace owl --create-namespace \
  -f values.lab.yaml \
  -f values.lab-secrets.yaml
```

Production/development use their respective values files.

## Values Layout

Top-level keys map directly to subcharts or umbrella-only templates:

- `owlstack`, `postgresql`, `redis`, `keycloak`, `zammad`, `keep`, `outline`, `garage`, `vector`
- `registryCredentials` (shared GHCR pull secret)
- `outlineSetup` (Outline API-token bootstrap hook + retry CronJob)
- `backup` (umbrella templated CronJob)
- `networkPolicies` (umbrella templated policies)

## Key Wiring

| From | To | Values |
|---|---|---|
| Owlstack | PostgreSQL | `owlstack.secrets.databaseUrl` |
| Owlstack | Redis | `owlstack.secrets.redisUrl` |
| Owlstack | Keycloak | `owlstack.secrets.oidcIssuerUrl`, `oidcClientId`, `oidcClientSecret` |
| Owlstack | Zammad | `owlstack.config.zammadUrl`, `owlstack.secrets.zammadToken` |
| Owlstack | Outline | `owlstack.config.outlineUrl`, `owlstack.secrets.outlineApiToken` |
| Owlstack worker | Keep API | `owlstack.config.keepUrl`, `owlstack.secrets.keepApiKey` |
| Keep | PostgreSQL | `keep.secrets.databaseConnectionString` |
| Keep | Keycloak | `keep.oauth2Proxy.*` + Keep `AUTH_TYPE=OAUTH2PROXY` env |
| Keep frontend/backend | Keep websocket | `/websocket` ingress path -> keep websocket service |
| Outline | PostgreSQL/Redis | `outline.secrets.databaseUrl`, `outline.secrets.redisUrl` |
| Outline | Keycloak | `outline.environment` OIDC settings |
| Outline | Garage | `outline.environment` AWS_* settings |
| Vector | Keep backend | `vector.customConfig.sinks.keep_alerts.uri` + `KEEP_API_KEY` secret |
| Vector | Owlstack keep-webhook endpoint | `vector.customConfig.sinks.nightowl_alerts.uri` + `OWLSTACK_WEBHOOK_KEY` secret |

## Keep SSO Notes

Keep OSS does not support native Keycloak auth mode. This chart uses:

1. `templates/keep-oauth2-proxy.yaml` (proxy deployment/service)
2. `templates/keep-oauth2-proxy-ingress.yaml` (frontend + `/backend/*` + `/websocket/*` routing)

If Keep login loops or websocket errors occur, validate those ingress routes first.

## Operational Add-ons

- `templates/job-outline-setup.yaml`: one-shot post-install/upgrade setup (fail-soft when no Outline admin exists yet)
- `templates/cronjob-outline-setup-retry.yaml`: periodic idempotent retry; auto-completes setup after first Outline OIDC login
- `templates/backup-cronjob.yaml`: daily `pg_dump` backups for configured databases
- `templates/network-policies.yaml`: component-level traffic restrictions

## Repo Structure

```text
umbrella-owl/
├── Chart.yaml
├── Chart.lock
├── values.yaml
├── values-dev.yaml
├── values-production.yaml
├── values.lab.yaml
├── templates/
│   ├── backup-cronjob.yaml
│   ├── network-policies.yaml
│   ├── keep-oauth2-proxy.yaml
│   ├── keep-oauth2-proxy-ingress.yaml
│   ├── secret-keep.yaml
│   ├── secret-outline.yaml
│   ├── keycloak-realm-import.yaml
│   └── ...
├── deploy/
├── docs/
│   ├── integration.md
│   ├── operations.md
│   └── operator-design.md
├── keycloak/
└── .github/workflows/
```

## CI/CD

- PR checks: `helm lint`, `helm template`, dependency validation
- Tag `v*`: package/publish umbrella chart to GHCR

## License

Proprietary - Wisbric.
