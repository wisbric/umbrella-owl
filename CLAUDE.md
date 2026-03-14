# CLAUDE.md — umbrella-owl

## Repo Purpose

`umbrella-owl` is the deployment orchestration repo for the owl platform.

It contains:

- Umbrella Helm chart metadata/dependencies
- Environment values (`values*.yaml`)
- Umbrella templates for cross-chart wiring (secrets, ingress helpers, backup, netpol)
- Integration and operations documentation

It does **not** contain Owlstack application code.

## Dependency Model

`Chart.yaml` dependencies include:

- `owlstack` via local chart path: `file://../owlstack/deploy/helm/owlstack`
- Third-party charts: PostgreSQL, Redis, Keycloak, Zammad, Keep, Outline, Garage, Vector

For external/public chart releases, Helm packages these dependencies into the release artifact.

## Critical Architecture Decisions

- Keep OSS authentication is implemented with `oauth2-proxy` (Keycloak OIDC) rather than native Keep Keycloak mode.
- Keep traffic is split across ingress paths:
  - `/` and `/oauth2/*` -> oauth2-proxy
  - `/backend/*` -> keep backend (nginx auth_request headers)
  - `/websocket/*` -> keep websocket service
- Outline authenticates directly with Keycloak OIDC and stores files in Garage (S3 API).
- Vector can push alerts to Keep (`/alerts/event`) using Keep API key auth.

## Most Important Files

- `Chart.yaml` / `Chart.lock`
- `values.yaml`, `values-dev.yaml`, `values-production.yaml`, `values.lab.yaml`
- `templates/keep-oauth2-proxy.yaml`
- `templates/keep-oauth2-proxy-ingress.yaml`
- `templates/secret-keep.yaml`, `templates/secret-outline.yaml`
- `templates/backup-cronjob.yaml`
- `templates/network-policies.yaml`
- `docs/integration.md`
- `docs/operations.md`

## Cross-Service Wiring Checklist

- Owlstack DB/Redis/OIDC/Zammad/Outline values set
- Owlstack webhook/Keep API secrets set (`OWLSTACK_WEBHOOK_KEY`, `OWLSTACK_KEEP_API_KEY`)
- Keep DB + oauth2-proxy values set
- Keep API keys set (`keepApiKey` for Vector ingest, `keepAdminApiKey` for Owlstack poller)
- Outline DB/Redis/OIDC/S3 values set
- Keycloak realm import placeholders matched to values
- Vector sink secrets present when vector is enabled (`KEEP_API_KEY`, `NIGHTOWL_API_KEY`)

## Lab Workflow

```bash
helm dep update .
helm upgrade --install owl . -n owl --create-namespace -f values.lab.yaml -f values.lab-secrets.yaml
```

## Conventions

- Never commit real secrets.
- Keep placeholder values in committed files.
- Bump umbrella chart version when dependency graph or value structure changes.
- After dependency version changes, run `helm dep update` and commit `Chart.lock`.
