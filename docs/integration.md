# Integration Guide

This document describes how Owlstack integrates with external services.

## Architecture

Owlstack is a unified Go binary that provides incident management, on-call, ticket orchestration, SLA tracking, and a customer portal. It replaces the previous three-service architecture (NightOwl + BookOwl + TicketOwl).

```
                     ┌──────────┐
                     │ Keycloak │  OIDC SSO
                     └──┬──┬──┬─┘
                        │  │  │
  ┌────────┐     ┌──────▼┐ │ ┌▼───────┐     ┌────────┐
  │  Keep  │◄────│oauth2 │ │ │Outline │────►│ Garage │
  │(alerts)│     │ proxy │ │ │ (wiki) │ S3  │  (S3)  │
  └───┬────┘     └───────┘ │ └───┬────┘     └────────┘
      │               ┌────▼────┐│
  webhooks            │Owlstack ││
      │               │ :8080   ││
      │               └──┬───┬──┘│
      │                  │   │   │
      │             ┌────▼┐ ┌▼───┴──┐
      └────────────►│Redis│ │Zammad │
                    └─────┘ └───────┘
                         │
                  ┌──────▼──────┐
                  │ PostgreSQL  │
                  └─────────────┘
```

## 1. Owlstack → Zammad

Owlstack is a thin orchestration layer over Zammad for ticket management. It never stores ticket content — only metadata, SLA state, and links. All ticket reads go through Zammad's REST API.

### Configuration

| Value | Description |
|-------|-------------|
| `owlstack.config.zammadUrl` | Zammad internal URL (e.g. `http://owl-zammad:8080`) |
| `owlstack.secrets.zammadToken` | API token for the `owlstack-service` Zammad user |

### Zammad REST client

Owlstack calls Zammad's REST API for ticket CRUD, article management, and user lookups. The client is in `internal/zammad/`.

### Webhook sync (Zammad → Owlstack)

Zammad fires webhooks to `POST /api/v1/webhooks/zammad` on ticket/article events. Owlstack validates the signature, pushes to a Redis stream, and returns 200 immediately. A worker process consumes events asynchronously.

### SLA tracking

Owlstack tracks SLA state independently from Zammad. Each ticket gets an SLA policy based on priority. A worker polls every 60 seconds, checks deadlines, fetches current Zammad ticket state, and fires alerts on first breach.

## 2. Owlstack → Outline

Owlstack integrates with [Outline](https://getoutline.com/) for knowledge management — runbooks, post-mortems, and document linking.

### Configuration

| Value | Description |
|-------|-------------|
| `owlstack.config.outlineUrl` | Outline public URL (e.g. `https://outline.example.com`) |
| `owlstack.secrets.outlineApiToken` | Outline API Bearer token |

### Runbooks

Owlstack syncs runbooks from Outline collections. The Outline client is in `internal/outline/`. Runbooks are cached locally and displayed in the incident detail view.

### Document linking

Agents can link Outline documents to tickets. Links are stored with snapshot metadata (slug, title) and visible in the ticket detail view.

### Post-mortem creation

When resolving an incident, operators can create a post-mortem document in Outline pre-filled with incident details (timeline, root cause, resolution).

## 3. Owlstack → Keep (AIOps)

[Keep](https://keephq.dev/) sends alerts to Owlstack via webhook.

### Configuration

Keep is configured to send webhooks to `POST /api/v1/webhooks/keep`. No Helm values needed — Keep configures the webhook URL on its side.

### Flow

1. Keep evaluates alert rules against incoming telemetry
2. Keep fires webhook to Owlstack with alert payload
3. Owlstack processes the alert, correlates with existing incidents
4. If no matching incident exists, Owlstack creates one

## 4. Owlstack → Keycloak (OIDC)

Owlstack uses Keycloak for authentication via OpenID Connect.

### Configuration

| Value | Description |
|-------|-------------|
| `owlstack.secrets.oidcIssuerUrl` | Keycloak realm URL (e.g. `https://keycloak.example.com/realms/owls`) |
| `owlstack.secrets.oidcClientId` | OIDC client ID (default: `nightowl`) |
| `owlstack.secrets.oidcClientSecret` | OIDC client secret |
| `owlstack.secrets.sessionSecret` | HMAC key for `wisbric_session` HttpOnly cookies |

### Flow

1. User visits Owlstack → redirected to Keycloak login
2. Keycloak authenticates user → redirects back with authorization code
3. Owlstack exchanges code for tokens, creates session cookie
4. Session validated on each request via middleware

## 5. Keep SSO via oauth2-proxy

Keep OSS does not support `AUTH_TYPE=KEYCLOAK` (Enterprise-only). The umbrella chart deploys an [oauth2-proxy](https://oauth2-proxy.github.io/oauth2-proxy/) instance in front of Keep for Keycloak SSO.

### Architecture

```
Browser → nginx Ingress → oauth2-proxy (:4180) → Keep frontend (:3000)
                              │
                              ▼
                        Keycloak OIDC
```

### Configuration

| Value | Description |
|-------|-------------|
| `keep.oauth2Proxy.enabled` | Deploy oauth2-proxy (default: `true` when keep is enabled) |
| `keep.oauth2Proxy.clientId` | Keycloak OIDC client ID (default: `keep`) |
| `keep.oauth2Proxy.issuerUrl` | Keycloak realm URL (e.g. `https://keycloak.devops.lab/realms/owls`) |
| `keep.oauth2Proxy.hostname` | Public hostname for Keep (e.g. `keep.devops.lab`) |
| `keep.oauth2Proxy.cookieSecret` | Cookie encryption secret (generate with `openssl rand -hex 16`) |
| `keep.oidcClientSecret` | OIDC client secret (must match Keycloak client config) |

### Flow

1. User visits `https://keep.devops.lab/`
2. nginx routes to oauth2-proxy
3. oauth2-proxy checks for valid session cookie (`_keep_oauth2`)
4. If no session: redirect to Keycloak login → auth code flow → set cookie
5. If valid session: proxy request to Keep frontend with `X-Auth-Request-User` and `X-Auth-Request-Email` headers
6. Keep reads auth headers via `AUTH_TYPE=OAUTH2PROXY`

### Templates

- `templates/keep-oauth2-proxy.yaml` — Deployment + Service
- `templates/keep-oauth2-proxy-ingress.yaml` — Ingress routing
- `templates/secret-keep.yaml` — K8s Secret (DB connection, NextAuth secret)

## 6. Outline OIDC

Outline connects directly to Keycloak via OIDC (no proxy needed).

### Configuration

| Value | Description |
|-------|-------------|
| `outline.oidcClientSecret` | Keycloak client secret (for realm import) |
| `outline.secrets.oidcClientSecret` | Same secret (injected as `OIDC_CLIENT_SECRET` env var) |
| `outline.environment` | OIDC_* env vars (auth URI, token URI, userinfo URI, etc.) |

### Flow

1. User visits `https://outline.devops.lab/`
2. Outline redirects to Keycloak for login
3. Keycloak authenticates → redirects back with auth code
4. Outline exchanges code for tokens, creates session
5. Outline uses `offline_access` scope for refresh tokens

### Important

- Outline requires `offline_access` in the Keycloak client's default scopes for refresh tokens
- The Keycloak client is configured in `keycloak/owls-realm.json`

## 7. Garage S3 Storage

[Garage](https://garagehq.deuxfleurs.fr/) provides S3-compatible storage for Outline file uploads.

### Configuration

| Value | Description |
|-------|-------------|
| `garage.garage.replicationFactor` | Number of data copies (`"1"` for single-node lab) |
| `garage.deployment.replicaCount` | Number of Garage pods |
| `garage.persistence.data.size` | Data volume size |

### Post-Deploy Setup

Garage requires manual setup after first deployment:

```bash
# 1. Check node status
kubectl exec -n owl owl-garage-0 -- ./garage status

# 2. Assign cluster layout (single-node)
kubectl exec -n owl owl-garage-0 -- ./garage layout assign -z dc1 -c 10G <node-id>
kubectl exec -n owl owl-garage-0 -- ./garage layout apply --version 1

# 3. Create access key for Outline
kubectl exec -n owl owl-garage-0 -- ./garage key create outline-key

# 4. Create bucket
kubectl exec -n owl owl-garage-0 -- ./garage bucket create outline

# 5. Grant permissions
kubectl exec -n owl owl-garage-0 -- ./garage bucket allow --read --write --owner outline --key outline-key

# 6. Get key credentials (use in Outline's AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY)
kubectl exec -n owl owl-garage-0 -- ./garage key info outline-key
```

### Outline ↔ Garage Wiring

Outline connects to Garage via S3-compatible API:

| Outline env var | Value |
|-----------------|-------|
| `AWS_S3_UPLOAD_BUCKET_URL` | `http://owl-garage:3900` |
| `AWS_S3_UPLOAD_BUCKET_NAME` | `outline` |
| `AWS_S3_FORCE_PATH_STYLE` | `true` |
| `AWS_REGION` | `garage` |

## 8. Cross-Service Summary

| From | To | Method | Purpose |
|------|----|--------|---------|
| Owlstack | Zammad | REST API | Ticket CRUD, article management |
| Zammad | Owlstack | Webhook | Ticket/article event notifications |
| Owlstack | Outline | REST API | Runbooks, document linking, post-mortems |
| Keep | Owlstack | Webhook | Alert ingestion |
| Owlstack | Keycloak | OIDC | Authentication |
| Keep | Keycloak | OIDC (via oauth2-proxy) | Authentication |
| Outline | Keycloak | OIDC (direct) | Authentication |
| Outline | Garage | S3 API | File storage |
| Owlstack | PostgreSQL | TCP | Primary data store |
| Keep | PostgreSQL | TCP | Alert data store |
| Outline | PostgreSQL | TCP | Wiki data store |
| Owlstack | Redis | TCP (DB 0) | Caching, event queues, sessions |
| Outline | Redis | TCP (DB 3) | Caching, sessions |
