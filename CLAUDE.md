# CLAUDE.md — umbrella-owl

## What This Repo Is

`umbrella-owl` is the umbrella Helm chart that deploys the entire Wisbric owl ecosystem as a single unit. It contains **no application code** — only Helm chart definitions, environment-specific values files, and CI configuration.

All subcharts (owl apps and third-party dependencies) are pulled from Helm registries at install time. Nothing is vendored.

## Architecture Decisions

| Decision | Detail |
|----------|--------|
| Chart format | Helm 3.8+ OCI artifacts — no legacy `index.yaml` repos |
| Owl chart registry | `oci://ghcr.io/wisbric/charts` (each owl repo pushes its own chart on merge to main) |
| Third-party charts | Pulled from upstream Helm registries (Bitnami, Zammad) |
| Values strategy | Single top-level `values.yaml` per environment with namespaced sections per subchart |
| Delivery layer | ArgoCD (Helm-first — no Flux, no Terraform) |
| Versioning | Umbrella chart version tracks independently; subchart versions pinned in `Chart.yaml` dependencies |

## Owl Ecosystem — Components

### Owlstack — Unified Operations Platform (NightOwl + TicketOwl)

- **Repo:** `github.com/wisbric/owlstack`
- **Chart name:** `owlstack`
- **Chart location (in source):** `deploy/helm/owlstack/`
- **Container images:** `ghcr.io/wisbric/owlstack` (API + worker), `ghcr.io/wisbric/owlstack-web` (frontend)
- **Deployments:** `api` (2 replicas), `worker` (1 replica), `frontend` (optional, disabled by default)
- **Ports:** API 8080, frontend 80
- **Requires:** PostgreSQL 16+, Redis 7+, Zammad 6.3+ (for ticket management)
- **Integrations:** OIDC, Slack, Mattermost, Twilio, Outline API, Zammad API, OpenTelemetry

### Third-Party Dependencies

| Dependency | Helm Registry | Purpose |
|------------|---------------|---------|
| `postgresql` | `oci://registry-1.docker.io/bitnamicharts/postgresql` | Shared database |
| `redis` | `oci://registry-1.docker.io/bitnamicharts/redis` | Caching, event queues |
| `keycloak` | `oci://registry-1.docker.io/bitnamicharts/keycloak` | OIDC identity provider (browser sessions use `wisbric_session` HttpOnly cookies via `core/pkg/auth`) |
| `zammad` | `https://zammad.github.io/zammad-helm` | Ticket engine backend |
| `keep` | `https://keephq.github.io/helm-charts` | AIOps alert management (SSO via oauth2-proxy) |
| `outline` | `https://helm.liam.sh` (lrstanley) | Collaborative wiki, replaces BookOwl |
| `garage` | `https://charts.derwitt.dev` | S3-compatible storage for Outline uploads |

## Repo Structure

```
umbrella-owl/
├── Chart.yaml                    # Umbrella chart metadata + dependency list
├── Chart.lock                    # Pinned dependency versions (generated)
├── Makefile                      # deploy-lab target for helm upgrade
├── values.yaml                   # Base/default values (all subcharts namespaced)
├── values-dev.yaml               # Dev/staging overrides
├── values-production.yaml        # Production overrides
├── values.lab.yaml               # Lab environment overrides
├── values.lab-secrets.yaml       # Lab secrets (not committed — gitignored)
├── templates/
│   ├── _helpers.tpl              # Shared template helpers
│   ├── NOTES.txt                 # Post-install instructions
│   ├── ghcr-secret.yaml          # GHCR image pull secret
│   ├── keycloak-realm-import.yaml # Keycloak realm bootstrap job
│   ├── job-zammad-setup.yaml     # Zammad service user setup job
│   ├── configmap-zammad-setup.yaml # Zammad setup SQL
│   ├── secret-keep.yaml          # Keep secrets (DB connection, NextAuth)
│   ├── secret-outline.yaml       # Outline secrets (keys, DB, Redis, OIDC)
│   ├── keep-oauth2-proxy.yaml    # oauth2-proxy Deployment + Service for Keep SSO
│   └── keep-oauth2-proxy-ingress.yaml # Ingress routing traffic through oauth2-proxy
├── deploy/
│   ├── apply-secrets.sh          # Helper to apply secrets to cluster
│   └── setup-zammad.sh           # Zammad initial setup script
├── keycloak/
│   └── owls-realm.json           # Keycloak realm export for owl apps
├── docs/
│   └── integration.md            # Cross-service integration notes
├── argocd/
│   ├── dev.yaml                  # ArgoCD Application for dev/staging
│   └── production.yaml           # ArgoCD Application for production
├── .helmignore
├── CLAUDE.md                     # This file
└── README.md                     # Human-facing documentation
```

## Cross-Service Wiring

These are the integration points that the umbrella values must wire together:

| From | To | Values to set |
|------|----|---------------|
| Owlstack | PostgreSQL | `owlstack.secrets.databaseUrl` |
| Owlstack | Redis | `owlstack.secrets.redisUrl` |
| Owlstack | Keycloak | `owlstack.secrets.oidcIssuerUrl`, `oidcClientId`, `oidcClientSecret` |
| Owlstack | Session secret | `owlstack.secrets.sessionSecret` (shared HMAC key for `wisbric_session` cookies) |
| Owlstack | Zammad | `owlstack.config.zammadUrl`, `owlstack.secrets.zammadToken` (defaults for seed tenant) |
| Owlstack | Outline | `owlstack.config.outlineUrl`, `owlstack.secrets.outlineApiToken` |
| Keep | PostgreSQL | `keep.secrets.databaseConnectionString` (SQLAlchemy format) |
| Keep | Keycloak | SSO via oauth2-proxy (`keep.oauth2Proxy.*`) — Keep OSS lacks native Keycloak support |
| Outline | PostgreSQL | `outline.secrets.databaseUrl` |
| Outline | Redis | `outline.secrets.redisUrl` (DB index 3) |
| Outline | Keycloak | OIDC directly (`outline.environment` OIDC_* vars) |
| Outline | Garage | S3 via `outline.environment` AWS_* vars |

## Lab Deployment

The lab environment uses `values.lab.yaml` and `values.lab-secrets.yaml`:

```bash
make deploy-lab    # helm dep update && helm upgrade -f values.lab.yaml -f values.lab-secrets.yaml
```

Lab images use `tag: main` with `pullPolicy: Always`. After CI builds complete, restart deployments to pick up new images.

## Conventions

- **Commit style:** Conventional commits (`feat:`, `fix:`, `docs:`, `chore:`)
- **Branch strategy:** PRs to `main`, version tags trigger releases
- **Chart versioning:** SemVer — bump `version` in `Chart.yaml` when changing umbrella chart structure or dependency versions
- **Subchart version bumps:** Update the `version` field in `Chart.yaml` dependencies, run `helm dep update`, commit the updated `Chart.lock`
- **No vendoring:** Never copy subchart tarballs into this repo — they are always pulled from registries
- **Secrets:** Never commit real secrets. Use placeholder values in committed files; real secrets injected via ArgoCD sealed secrets, external-secrets-operator, or Helm `--set`
