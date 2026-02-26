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

### NightOwl — Incident & On-Call Platform

- **Repo:** `github.com/wisbric/nightowl`
- **Chart name:** `nightowl`
- **Chart location (in source):** `deploy/helm/nightowl/`
- **Container images:** `ghcr.io/wisbric/nightowl` (API + worker), `ghcr.io/wisbric/nightowl-web` (frontend)
- **Deployments:** `api` (2 replicas), `worker` (1 replica), `frontend` (optional, disabled by default)
- **Ports:** API 8080, frontend 80
- **Requires:** PostgreSQL 16+, Redis 7+
- **Integrations:** OIDC, Slack, Mattermost, Twilio, BookOwl API, OpenTelemetry

### BookOwl — Knowledge Management Platform

- **Repo:** `github.com/wisbric/bookowl`
- **Chart name:** `bookowl`
- **Chart location (in source):** `deploy/helm/bookowl/`
- **Container images:** `ghcr.io/wisbric/bookowl` (API), `ghcr.io/wisbric/bookowl-web` (frontend), `ghcr.io/wisbric/bookowl-collab` (Hocuspocus collab server)
- **Deployments:** `api` (2 replicas), `web` (2 replicas), `collab` (2 replicas)
- **Ports:** API 8081, web 80, collab 1234
- **Requires:** PostgreSQL 16+, Redis 7+, S3-compatible storage (MinIO or AWS S3)
- **Integrations:** OIDC, NightOwl API, OpenTelemetry

### TicketOwl — Ticket Management Portal

- **Repo:** `github.com/wisbric/ticketowl`
- **Chart name:** `ticketowl`
- **Chart location (in source):** `charts/ticketowl/`
- **Container images:** `ghcr.io/wisbric/ticketowl` (API + worker)
- **Deployments:** `api` (2 replicas), `worker` (1 replica), `migration` (pre-deploy Job)
- **Ports:** API 8082
- **Requires:** PostgreSQL 16+, Redis 7+, Zammad 6.3+
- **Integrations:** OIDC, NightOwl API, BookOwl API, Zammad API, OpenTelemetry

### Third-Party Dependencies

| Dependency | Helm Registry | Purpose |
|------------|---------------|---------|
| `postgresql` | `oci://registry-1.docker.io/bitnamicharts/postgresql` | Shared database (or one per owl app) |
| `redis` | `oci://registry-1.docker.io/bitnamicharts/redis` | Caching, event queues |
| `keycloak` | `oci://registry-1.docker.io/bitnamicharts/keycloak` | OIDC identity provider shared by all owl apps (browser sessions use `wisbric_session` HttpOnly cookies via `core/pkg/auth`) |
| `zammad` | `https://zammad.github.io/zammad-helm` | Ticket engine (TicketOwl backend) |
| `minio` | `oci://registry-1.docker.io/bitnamicharts/minio` | S3-compatible object storage for BookOwl images (optional — can use AWS S3 instead) |

## Repo Structure

```
umbrella-owl/
├── Chart.yaml                    # Umbrella chart metadata + dependency list
├── Chart.lock                    # Pinned dependency versions (generated)
├── values.yaml                   # Base/default values (all subcharts namespaced)
├── values-dev.yaml               # Dev/staging overrides
├── values-production.yaml        # Production overrides
├── templates/
│   ├── _helpers.tpl              # Shared template helpers
│   └── NOTES.txt                 # Post-install instructions
├── argocd/
│   ├── dev.yaml                  # ArgoCD Application for dev/staging
│   └── production.yaml           # ArgoCD Application for production
├── .github/
│   └── workflows/
│       ├── lint.yml              # Helm lint + template validation on PRs
│       └── release.yml           # Package and push umbrella chart to GHCR on tag
├── .helmignore
├── CLAUDE.md                     # This file
└── README.md                     # Human-facing documentation
```

## Chart.yaml Dependencies

```yaml
apiVersion: v2
name: umbrella-owl
description: Umbrella Helm chart for the Wisbric owl ecosystem
type: application
version: 0.1.0
appVersion: "0.1.0"

dependencies:
  # Owl applications — OCI from GHCR
  - name: nightowl
    version: "0.1.0"
    repository: oci://ghcr.io/wisbric/charts
  - name: bookowl
    version: "0.1.0"
    repository: oci://ghcr.io/wisbric/charts
  - name: ticketowl
    version: "0.1.0"
    repository: oci://ghcr.io/wisbric/charts

  # Third-party — upstream Helm registries
  - name: postgresql
    version: "16.4.1"
    repository: oci://registry-1.docker.io/bitnamicharts
    condition: postgresql.enabled
  - name: redis
    version: "20.6.2"
    repository: oci://registry-1.docker.io/bitnamicharts
    condition: redis.enabled
  - name: keycloak
    version: "24.4.5"
    repository: oci://registry-1.docker.io/bitnamicharts
    condition: keycloak.enabled
  - name: zammad
    version: "10.3.0"
    repository: https://zammad.github.io/zammad-helm
    condition: zammad.enabled
  - name: minio
    version: "14.8.5"
    repository: oci://registry-1.docker.io/bitnamicharts
    condition: minio.enabled
```

> **Note:** Version numbers above are placeholders. Pin to the latest stable release at time of creation by checking each registry.

## Values Namespacing

The top-level `values.yaml` uses Helm's subchart namespacing convention. Each subchart's values live under a key matching its chart name:

```yaml
# Owl apps
nightowl:
  image:
    tag: "v0.1.0"
  secrets:
    databaseUrl: "postgres://..."
  # ... all nightowl chart values

bookowl:
  image:
    tag: "v0.1.0"
  secrets:
    databaseUrl: "postgres://..."

ticketowl:
  image:
    tag: "v0.1.0"
  secrets:
    dbUrl: "postgres://..."

# Third-party
postgresql:
  enabled: true
  auth:
    postgresPassword: ""
  # ...

redis:
  enabled: true
  # ...

keycloak:
  enabled: true
  # ...

zammad:
  enabled: true
  # ...

minio:
  enabled: false
  # ...
```

## Cross-Service Wiring

These are the integration points that the umbrella values must wire together:

| From | To | Values to set |
|------|----|---------------|
| NightOwl | PostgreSQL | `nightowl.secrets.databaseUrl` |
| NightOwl | Redis | `nightowl.secrets.redisUrl` |
| NightOwl | Keycloak | `nightowl.secrets.oidcIssuerUrl`, `oidcClientId`, `oidcClientSecret` |
| NightOwl | Session secret | `nightowl.secrets.sessionSecretKey` (shared HMAC key for `wisbric_session` cookies) |
| NightOwl | BookOwl | Tenant-level config (not Helm values — configured per-tenant at runtime) |
| BookOwl | PostgreSQL | `bookowl.secrets.databaseUrl` |
| BookOwl | Redis | `bookowl.secrets.redisUrl` |
| BookOwl | Keycloak | `bookowl.secrets.oidcIssuer`, `oidcClientId`, `oidcClientSecret` |
| BookOwl | Session secret | `bookowl.secrets.sessionSecretKey` (must match NightOwl's for cross-service SSO) |
| BookOwl | S3/MinIO | `bookowl.config.storageBackend`, `s3Endpoint`, `s3Bucket`, etc. |
| BookOwl | NightOwl | `bookowl.config.nightowlApiUrl`, `bookowl.secrets.nightowlApiKey` |
| TicketOwl | PostgreSQL | `ticketowl.secrets.dbUrl` |
| TicketOwl | Redis | `ticketowl.secrets.redisUrl` |
| TicketOwl | Keycloak | `ticketowl.secrets.oidcIssuer`, `oidcClientId` |
| TicketOwl | Session secret | `ticketowl.secrets.sessionSecretKey` (must match NightOwl's for cross-service SSO) |
| TicketOwl | Zammad | Tenant-level config (Zammad URL + API token stored per-tenant in DB) |
| TicketOwl | NightOwl | `ticketowl.config.nightowlApiUrl`, `ticketowl.secrets.nightowlApiKey` |
| TicketOwl | BookOwl | `ticketowl.config.bookowlApiUrl`, `ticketowl.secrets.bookowlApiKey` |

## GitHub Actions — Owl Repo Chart Publishing

Each owl repo needs a workflow step that packages and pushes its Helm chart to GHCR on merge to main. This is **not in this repo** — it runs in each owl repo's CI. The pattern:

```yaml
# In each owl repo's .github/workflows/release.yml
- name: Push Helm chart
  run: |
    echo "${{ secrets.GITHUB_TOKEN }}" | helm registry login ghcr.io -u ${{ github.actor }} --password-stdin
    helm package deploy/helm/<chart-name>
    helm push <chart-name>-*.tgz oci://ghcr.io/wisbric/charts
```

Chart locations per repo:
- **nightowl:** `deploy/helm/nightowl/`
- **bookowl:** `deploy/helm/bookowl/`
- **ticketowl:** `charts/ticketowl/`

## GitHub Actions — This Repo

### `lint.yml` (on PRs)
1. `helm lint .` — validate chart structure
2. `helm template umbrella-owl .` — verify templates render without errors
3. `helm dep build .` — verify all dependencies resolve

### `release.yml` (on version tags `v*`)
1. `helm dep build .` — pull all subchart dependencies
2. `helm package .` — package the umbrella chart
3. `helm push umbrella-owl-*.tgz oci://ghcr.io/wisbric/charts` — push to GHCR

## Prioritised Task List

### Phase 1 — Scaffold the Umbrella Chart
1. Create `Chart.yaml` with all dependencies (owl apps + third-party)
2. Create base `values.yaml` with namespaced defaults for every subchart
3. Create `templates/NOTES.txt` with post-install summary and access instructions
4. Create `templates/_helpers.tpl` with shared helpers
5. Create `.helmignore`

### Phase 2 — Environment Values Files
6. Create `values-dev.yaml` — dev/staging overrides (lower resources, debug logging, dev image tags)
7. Create `values-production.yaml` — production overrides (real secrets placeholders, production resources, ingress with TLS)

### Phase 3 — CI Pipeline for This Repo
8. Create `.github/workflows/lint.yml` — helm lint + template render on PRs
9. Create `.github/workflows/release.yml` — package + push umbrella chart on version tags

### Phase 4 — Chart Publishing Stubs for Owl Repos
10. Add `helm-release` job stub to `nightowl/.github/workflows/release.yml`
11. Add `helm-release` job stub to `bookowl/.github/workflows/release.yml`
12. Add `helm-release` job stub to `ticketowl/.github/workflows/ci.yml` (ticketowl has no separate release workflow yet)

### Phase 5 — ArgoCD Integration
13. Create `argocd/` directory with example Application manifests (one per environment)
14. Document ArgoCD setup in README.md

### Phase 6 — Validation & Docs
15. Run `helm dep build` and `helm template` to validate everything resolves
16. Verify cross-service wiring is correct in values files
17. Final README.md review

## Conventions

- **Commit style:** Conventional commits (`feat:`, `fix:`, `docs:`, `chore:`)
- **Branch strategy:** PRs to `main`, version tags trigger releases
- **Chart versioning:** SemVer — bump `version` in `Chart.yaml` when changing umbrella chart structure or dependency versions
- **Subchart version bumps:** Update the `version` field in `Chart.yaml` dependencies, run `helm dep update`, commit the updated `Chart.lock`
- **No vendoring:** Never copy subchart tarballs into this repo — they are always pulled from registries
- **Secrets:** Never commit real secrets. Use placeholder values in committed files; real secrets injected via ArgoCD sealed secrets, external-secrets-operator, or Helm `--set`
