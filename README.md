# umbrella-owl

Umbrella Helm chart that deploys the entire Wisbric owl ecosystem — [Owlstack](https://github.com/wisbric/owlstack) (unified operations platform) and its third-party dependencies — as a single deployable unit.

## What's Included

### Owl Applications

| Chart | Description | Registry |
|-------|-------------|----------|
| `owlstack` | Unified operations platform — incident management, on-call, ticket orchestration, SLA tracking, customer portal | `oci://ghcr.io/wisbric/charts/owlstack` |

### Third-Party Dependencies

| Chart | Description | Registry | Condition |
|-------|-------------|----------|-----------|
| `postgresql` | Shared PostgreSQL 16 database | Bitnami OCI | `postgresql.enabled` |
| `redis` | Shared Redis 7 for caching and event queues | Bitnami OCI | `redis.enabled` |
| `keycloak` | OIDC identity provider (shared SSO) | Bitnami OCI | `keycloak.enabled` |
| `zammad` | Ticket engine backend | Zammad Helm repo | `zammad.enabled` |
| `keep` | AIOps alert management (SSO via oauth2-proxy) | [keephq](https://keephq.github.io/helm-charts) | `keep.enabled` |
| `outline` | Collaborative wiki (replaces BookOwl) | [lrstanley](https://helm.liam.sh) | `outline.enabled` |
| `garage` | S3-compatible storage for Outline uploads | [derwitt](https://charts.derwitt.dev) | `garage.enabled` |

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
  --set owlstack.secrets.databaseUrl="postgres://..." \
  --set owlstack.secrets.redisUrl="redis://..."
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
owlstack:         # All owlstack chart values
  image:
    tag: "main"
  replicaCount:
    api: 2
    worker: 1
  config:
    zammadUrl: ""
    outlineUrl: ""
  secrets:
    databaseUrl: ""
    redisUrl: ""
    encryptionKey: ""
    zammadToken: ""
    outlineApiToken: ""

postgresql:       # Bitnami PostgreSQL chart values
  enabled: true

redis:            # Bitnami Redis chart values
  enabled: true

keycloak:         # Bitnami Keycloak chart values
  enabled: true

zammad:           # Zammad chart values
  enabled: true

keep:             # Keep chart values (AIOps alerts)
  enabled: true

outline:          # Outline chart values (wiki)
  enabled: true

garage:           # Garage chart values (S3 storage)
  enabled: true
```

Refer to the owlstack subchart values for the full list of configurable options:

- **owlstack:** [`deploy/helm/owlstack/values.yaml`](https://github.com/wisbric/owlstack/blob/main/deploy/helm/owlstack/values.yaml)

## Cross-Service Wiring

```
                    ┌──────────┐
                    │ Keycloak │  (OIDC SSO)
                    └──┬──┬──┬─┘
                       │  │  │
                ┌──────▼┐ │ ┌▼───────┐
                │  Keep │ │ │Outline │
                │(proxy)│ │ │ (wiki) │
                └───────┘ │ └───┬────┘
                     ┌────▼────┐│
                     │Owlstack ││    ┌────────┐
                     │ :8080   ││    │ Garage │
                     └──┬───┬──┘│    │  (S3)  │
                        │   │   │    └───▲────┘
                   ┌────▼┐ ┌▼───┴──┐     │
                   │Redis│ │Zammad │     │
                   └─────┘ └───────┘  Outline
                        │              uploads
                 ┌──────▼──────┐
                 │ PostgreSQL  │
                 └─────────────┘
```

| Connection | What to set |
|------------|-------------|
| Owlstack → PostgreSQL | `owlstack.secrets.databaseUrl` |
| Owlstack → Redis | `owlstack.secrets.redisUrl` |
| Owlstack → Keycloak | `owlstack.secrets.oidcIssuerUrl`, `oidcClientId`, `oidcClientSecret` |
| Owlstack → Session secret | `owlstack.secrets.sessionSecret` (HMAC key for `wisbric_session` cookies) |
| Owlstack → Zammad | `owlstack.config.zammadUrl`, `owlstack.secrets.zammadToken` |
| Owlstack → Outline | `owlstack.config.outlineUrl`, `owlstack.secrets.outlineApiToken` |
| Keep → PostgreSQL | `keep.secrets.databaseConnectionString` (via umbrella Secret) |
| Keep → Keycloak | SSO via oauth2-proxy (`keep.oauth2Proxy.*`) |
| Outline → PostgreSQL | `outline.secrets.databaseUrl` (via umbrella Secret) |
| Outline → Redis | `outline.secrets.redisUrl` (DB index 3, via umbrella Secret) |
| Outline → Keycloak | OIDC directly (`outline.environment` OIDC_* vars) |
| Outline → Garage | S3 uploads (`outline.environment` AWS_* vars) |

## Versioning

This repo follows [SemVer](https://semver.org/):

- **Umbrella chart version** (`version` in `Chart.yaml`): tracks changes to the umbrella chart itself — dependency version bumps, values structure changes
- **Subchart versions**: pinned in `Chart.yaml` `dependencies[].version` and locked in `Chart.lock`
- **App versions**: owlstack has its own release cadence; image tags are set in the values files

### Version bump workflow

1. Update the subchart `version` in `Chart.yaml` dependencies
2. Run `helm dep update .` to refresh `Chart.lock`
3. Update image tags in the relevant values file if needed
4. Commit `Chart.yaml` + `Chart.lock`
5. Tag with `vX.Y.Z` to trigger the release pipeline

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

## CI/CD

### This repo

| Workflow | Trigger | What it does |
|----------|---------|--------------|
| `helm-lint.yml` | PRs to `main` | `helm lint`, `helm template`, `helm dep build` validation |
| `helm-release.yml` | Tags matching `v*` | Package umbrella chart and push to `oci://ghcr.io/wisbric/charts` |

### Owl repos (chart publishing)

| Repo | Chart directory | Trigger |
|------|----------------|---------|
| `owlstack` | `deploy/helm/owlstack/` | Push to `main` + `v*` tags |

## Repo Structure

```
umbrella-owl/
├── Chart.yaml              # Chart metadata + all subchart dependencies
├── Chart.lock              # Pinned versions (helm dep update generates this)
├── values.yaml             # Base defaults for all subcharts
├── values-dev.yaml         # Dev/staging overrides
├── values-production.yaml  # Production overrides (secrets via --set or external-secrets)
├── values.lab.yaml         # Lab environment overrides
├── templates/
│   ├── _helpers.tpl        # Shared template helpers
│   ├── NOTES.txt           # Post-install instructions
│   ├── ghcr-secret.yaml    # GHCR image pull secret
│   ├── frontend-dns-aliases.yaml  # DNS aliases for frontend nginx
│   ├── keycloak-realm-import.yaml # Keycloak realm bootstrap job
│   ├── job-zammad-setup.yaml      # Zammad service user setup job
│   ├── configmap-zammad-setup.yaml # Zammad setup SQL
│   ├── secret-keep.yaml           # Keep secrets (DB, NextAuth)
│   ├── secret-outline.yaml        # Outline secrets (keys, DB, Redis, OIDC)
│   ├── keep-oauth2-proxy.yaml     # oauth2-proxy for Keep SSO
│   └── keep-oauth2-proxy-ingress.yaml # Ingress for Keep via oauth2-proxy
├── keycloak/
│   └── owls-realm.json     # Keycloak realm export
├── deploy/
│   ├── apply-secrets.sh    # Generate lab secrets
│   └── setup-zammad.sh     # Zammad initial setup
├── argocd/
│   ├── dev.yaml            # ArgoCD Application for dev/staging
│   └── production.yaml     # ArgoCD Application for production
├── .github/
│   └── workflows/
│       ├── helm-lint.yml   # PR validation
│       └── helm-release.yml # Chart publishing on tags
├── .helmignore
├── CLAUDE.md               # Project context for Claude Code
└── README.md               # This file
```

## License

Proprietary — Wisbric.
