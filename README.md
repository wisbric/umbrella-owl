# umbrella-owl

Umbrella Helm chart that deploys the entire Wisbric owl ecosystem — [NightOwl](https://github.com/wisbric/nightowl), [BookOwl](https://github.com/wisbric/bookowl), [TicketOwl](https://github.com/wisbric/ticketowl), and their third-party dependencies — as a single deployable unit.

## What's Included

### Owl Applications

| Chart | Description | Registry |
|-------|-------------|----------|
| `nightowl` | Incident management, on-call rosters, alert routing, escalation engine | `oci://ghcr.io/wisbric/charts/nightowl` |
| `bookowl` | Knowledge base, runbooks, real-time collaborative editor, post-mortems | `oci://ghcr.io/wisbric/charts/bookowl` |
| `ticketowl` | Ticket management portal over Zammad, SLA tracking, customer portal | `oci://ghcr.io/wisbric/charts/ticketowl` |

### Third-Party Dependencies

| Chart | Description | Registry | Condition |
|-------|-------------|----------|-----------|
| `postgresql` | Shared PostgreSQL 16 database | Bitnami OCI | `postgresql.enabled` |
| `redis` | Shared Redis 7 for caching and event queues | Bitnami OCI | `redis.enabled` |
| `keycloak` | OIDC identity provider (shared SSO) | Bitnami OCI | `keycloak.enabled` |
| `zammad` | Ticket engine backend for TicketOwl | Zammad Helm repo | `zammad.enabled` |
| `minio` | S3-compatible object storage for BookOwl images | Bitnami OCI | `minio.enabled` |

All third-party dependencies are optional — disable them and point to external services instead.

## Prerequisites

- Kubernetes 1.27+
- Helm 3.8+ (OCI registry support required)
- `kubectl` configured for the target cluster
- GHCR access for pulling owl chart images (public, or an `imagePullSecret` for private repos)

## Quick Start

```bash
# Pull dependencies
helm dep build .

# Install (dev)
helm install owl . \
  --namespace owl --create-namespace \
  -f values-dev.yaml

# Install (production)
helm install owl . \
  --namespace owl --create-namespace \
  -f values-production.yaml \
  --set nightowl.secrets.databaseUrl="postgres://..." \
  --set bookowl.secrets.databaseUrl="postgres://..." \
  --set ticketowl.secrets.dbUrl="postgres://..."
```

## Upgrade

```bash
# Update subchart dependency versions in Chart.yaml, then:
helm dep update .
helm upgrade owl . --namespace owl -f values-production.yaml
```

## Configuration

This chart uses a single `values.yaml` per environment. Each subchart's configuration lives under a key matching its chart name:

```yaml
# values.yaml structure
nightowl:        # All nightowl chart values
  image:
    tag: "v0.1.0"
  replicaCount:
    api: 2
    worker: 1
  secrets:
    databaseUrl: ""
    redisUrl: ""

bookowl:          # All bookowl chart values
  image:
    tag: "v0.1.0"
  secrets:
    databaseUrl: ""
    redisUrl: ""

ticketowl:        # All ticketowl chart values
  image:
    tag: "v0.1.0"
  secrets:
    dbUrl: ""
    redisUrl: ""

postgresql:       # Bitnami PostgreSQL chart values
  enabled: true

redis:            # Bitnami Redis chart values
  enabled: true

keycloak:         # Bitnami Keycloak chart values
  enabled: true

zammad:           # Zammad chart values
  enabled: true

minio:            # Bitnami MinIO chart values
  enabled: false  # Use AWS S3 in production
```

Refer to each subchart's `values.yaml` for the full list of configurable options:

- **nightowl:** [`deploy/helm/nightowl/values.yaml`](https://github.com/wisbric/nightowl/blob/main/deploy/helm/nightowl/values.yaml)
- **bookowl:** [`deploy/helm/bookowl/values.yaml`](https://github.com/wisbric/bookowl/blob/main/deploy/helm/bookowl/values.yaml)
- **ticketowl:** [`charts/ticketowl/values.yaml`](https://github.com/wisbric/ticketowl/blob/main/charts/ticketowl/values.yaml)

## Cross-Service Wiring

The owl applications communicate with each other and shared infrastructure. Key integration points to configure:

```
                  ┌──────────┐
                  │ Keycloak │  (OIDC SSO for all owl apps)
                  └────┬─────┘
                       │
         ┌─────────────┼─────────────┐
         │             │             │
    ┌────▼────┐   ┌────▼────┐   ┌───▼──────┐
    │NightOwl │◄──│ BookOwl │   │TicketOwl │
    │ :8080   │──►│ :8081   │   │ :8082    │
    └────┬────┘   └────┬────┘   └───┬──────┘
         │             │             │
         │             │        ┌────▼────┐
         │             │        │ Zammad  │
         │             │        └─────────┘
    ┌────▼─────────────▼─────────────┘
    │       PostgreSQL + Redis       │
    └────────────────────────────────┘
```

| Connection | What to set |
|------------|-------------|
| All apps → PostgreSQL | `<app>.secrets.databaseUrl` (or `dbUrl` for ticketowl) |
| All apps → Redis | `<app>.secrets.redisUrl` |
| All apps → Keycloak | `<app>.secrets.oidcIssuerUrl` / `oidcIssuer`, `oidcClientId`, `oidcClientSecret` |
| BookOwl → NightOwl | `bookowl.config.nightowlApiUrl`, `bookowl.secrets.nightowlApiKey` |
| TicketOwl → NightOwl | `ticketowl.config.nightowlApiUrl`, `ticketowl.secrets.nightowlApiKey` |
| TicketOwl → BookOwl | `ticketowl.config.bookowlApiUrl`, `ticketowl.secrets.bookowlApiKey` |
| BookOwl → S3/MinIO | `bookowl.config.storageBackend: s3`, `s3Endpoint`, `s3Bucket`, etc. |
| TicketOwl → Zammad | Per-tenant config (stored in TicketOwl DB, not Helm values) |

## Versioning

This repo follows [SemVer](https://semver.org/):

- **Umbrella chart version** (`version` in `Chart.yaml`): tracks changes to the umbrella chart itself — dependency version bumps, values structure changes, new subcharts added
- **Subchart versions**: pinned in `Chart.yaml` `dependencies[].version` and locked in `Chart.lock`
- **App versions**: each owl app has its own release cadence; image tags are set in the values files

### Version bump workflow

1. Update the subchart `version` in `Chart.yaml` dependencies
2. Run `helm dep update .` to refresh `Chart.lock`
3. Update image tags in the relevant values file if needed
4. Commit `Chart.yaml` + `Chart.lock`
5. Tag with `vX.Y.Z` to trigger the release pipeline

## Adding a New Subchart

1. **Add the dependency** to `Chart.yaml`:

   ```yaml
   dependencies:
     # ...existing deps...
     - name: new-service
       version: "1.0.0"
       repository: oci://ghcr.io/wisbric/charts  # or upstream registry URL
       condition: new-service.enabled
   ```

2. **Add default values** to `values.yaml`:

   ```yaml
   new-service:
     enabled: true
     # ... subchart values
   ```

3. **Add environment overrides** to `values-dev.yaml` and `values-production.yaml`

4. **Pull the dependency**:

   ```bash
   helm dep update .
   ```

5. **Verify**:

   ```bash
   helm lint .
   helm template umbrella-owl .
   ```

6. **Commit** `Chart.yaml`, `Chart.lock`, and values files. **Do not** commit the `charts/` directory — it is in `.helmignore` and populated by `helm dep build`.

## How Owl Charts Get Published

Each owl repo has a GitHub Actions release workflow that packages and pushes its Helm chart to GHCR on merge to `main`:

```
┌─────────────────┐     helm package + push     ┌───────────────────────────┐
│ nightowl repo   │ ──────────────────────────► │ oci://ghcr.io/wisbric/    │
│ bookowl repo    │         (on main merge)      │       charts/nightowl    │
│ ticketowl repo  │                              │       charts/bookowl     │
└─────────────────┘                              │       charts/ticketowl   │
                                                 └───────────┬───────────────┘
                                                             │
                                                   helm dep build
                                                             │
                                                 ┌───────────▼───────────────┐
                                                 │   umbrella-owl            │
                                                 │   (this repo)             │
                                                 └───────────────────────────┘
```

The release workflow in each owl repo runs:

```bash
helm registry login ghcr.io -u $GITHUB_ACTOR --password-stdin <<< "$GITHUB_TOKEN"
helm package <chart-dir>
helm push <chart>-*.tgz oci://ghcr.io/wisbric/charts
```

## Deployment with ArgoCD

This chart is designed for ArgoCD as the delivery layer. Ready-to-use Application manifests are in `argocd/`:

| File | Environment | Namespace | Sync policy |
|------|-------------|-----------|-------------|
| `argocd/dev.yaml` | Dev / staging | `owl-dev` | Automated (prune + self-heal) |
| `argocd/production.yaml` | Production | `owl` | Manual sync (no auto-prune) |

Apply with:

```bash
kubectl apply -f argocd/dev.yaml
kubectl apply -f argocd/production.yaml
```

Both manifests pull the `umbrella-owl` chart from `ghcr.io/wisbric/charts` and reference the matching values file. Edit `targetRevision` to pin the chart version per environment.

For additional environments, copy an existing manifest and adjust `metadata.name`, `destination.namespace`, `targetRevision`, and `valueFiles`.

## CI/CD

### This repo

| Workflow | Trigger | What it does |
|----------|---------|--------------|
| `lint.yml` | PRs to `main` | `helm lint`, `helm template`, `helm dep build` validation |
| `release.yml` | Tags matching `v*` | Package umbrella chart and push to `oci://ghcr.io/wisbric/charts` |

### Owl repos (chart publishing)

Each owl repo's release workflow includes a `helm-release` job:

| Repo | Chart directory | Trigger |
|------|----------------|---------|
| `nightowl` | `deploy/helm/nightowl/` | Push to `main` + `v*` tags |
| `bookowl` | `deploy/helm/bookowl/` | Push to `main` + `v*` tags |
| `ticketowl` | `charts/ticketowl/` | Push to `main` + `v*` tags |

## Repo Structure

```
umbrella-owl/
├── Chart.yaml              # Chart metadata + all subchart dependencies
├── Chart.lock              # Pinned versions (helm dep update generates this)
├── values.yaml             # Base defaults for all subcharts
├── values-dev.yaml         # Dev/staging overrides
├── values-production.yaml  # Production overrides (secrets via --set or external-secrets)
├── templates/
│   ├── _helpers.tpl        # Shared template helpers
│   └── NOTES.txt           # Post-install instructions
├── argocd/
│   ├── dev.yaml            # ArgoCD Application for dev/staging
│   └── production.yaml     # ArgoCD Application for production
├── .github/
│   └── workflows/
│       ├── lint.yml        # PR validation
│       └── release.yml     # Chart publishing on tags
├── .helmignore
├── CLAUDE.md               # Project context for Claude Code
└── README.md               # This file
```

## License

Proprietary — Wisbric.
