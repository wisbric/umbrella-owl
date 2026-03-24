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

- `owlstack` — dual-mode dependency:
  - **Local dev:** `file://../owlstack/deploy/helm/owlstack` (edit `Chart.yaml` repository field)
  - **CI releases:** `oci://registry.gitlab.com/adfinisde/agentic-workspace/ai-ops/owlstack/charts` (published by owlstack CI)
- Third-party charts: PostgreSQL, Redis, Zammad, Keep, Outline, Garage, Vector
- Keycloak is external (central platform Keycloak at `keycloak.mgmt.dev-ai.wisbric.com/realms/platform`)

Current versions: owlstack `0.4.2`, umbrella-owl `0.7.4`.

For CI releases, Helm packages all dependencies (including the OCI-sourced owlstack chart) into the release artifact.

## Critical Architecture Decisions

- Keep OSS authentication uses `oauth2-proxy` (Keycloak OIDC) via nginx **auth_request** pattern (not as upstream proxy). Requires Keep >= 0.49.0 for the `OAuth2Proxy` NextAuth credentials provider.
- Keep traffic is split across three ingresses:
  - `/oauth2/*` -> oauth2-proxy (login/callback/auth validation only)
  - `/` -> Keep frontend directly (nginx validates via auth_request to oauth2-proxy `/oauth2/auth`, forwards identity headers)
  - `/backend/*`, `/websocket/*` -> Keep backend/websocket (nginx validates via auth_request, forwards identity headers)
- nginx `proxy-buffer-size: 16k` required on oauth2-proxy ingress (Keycloak session cookies exceed default 4KB)
- Outline authenticates directly with Keycloak OIDC and stores files in Garage (S3 API).
- Vector can push alerts to Keep (`/alerts/event`) using Keep API key auth.

## MCP Servers (AI Agent Integration)

Umbrella chart deploys optional MCP servers for AI agent integration (all gated by `mcpServers.{service}.enabled`):

- `templates/mcp-ingress.yaml` — ingress at `nightowl.ops.dev-ai.wisbric.com/mcp/`
- `templates/mcp-k8s.yaml` — K8s MCP server (Red Hat, read-only) with RBAC
- `templates/mcp-keep.yaml` — Keep MCP server (`registry.gitlab.com/adfinisde/agentic-workspace/ai-ops/keep-mcp`)
- `templates/mcp-postgres.yaml` — PostgreSQL MCP server (Anthropic official)

The owlstack MCP server itself is deployed by the owlstack subchart (`owlstack.mcp.enabled`).

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
- OIDC issuer URL set to central platform Keycloak (global.oidc.issuerUrl)
- Vector sink secrets present when vector is enabled (`KEEP_API_KEY`, `NIGHTOWL_API_KEY`)

## Lab Workflow

The primary deployment method is **ArgoCD** from the management cluster. See `dev-ai-ionos/argocd/apps/platform/owl.yaml` for the app definition.

For local development or manual overrides:

```bash
helm dep update .
helm upgrade --install owl . -n owl --create-namespace -f values.lab.yaml -f values.lab-secrets.yaml
```

## ESO / Secrets

The umbrella chart includes External Secrets Operator (ESO) templates for pulling secrets from OpenBao:

- `templates/external-secret-*.yaml` — 7 ExternalSecrets: owlstack, keep, outline, postgresql, redis, zammad, registry
- `templates/secret-store.yaml` — SecretStore for OpenBao connection
- OpenBao paths: `secret/platform/owl/*`
- Kubernetes auth: service account `owl-eso`, role `eso-owl`, auth path `kubernetes-projects`

Gated by `externalSecrets.enabled` — when `false`, secrets are provided via manual Helm values.

## Conventions

- Never commit real secrets.
- Keep placeholder values in committed files.
- Bump umbrella chart version when dependency graph or value structure changes.
- After dependency version changes, run `helm dep update` and commit `Chart.lock`.
