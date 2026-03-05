# Integration Guide

Current integration map for the deployed owl platform.

## Architecture

Owlstack is the unified operations app. Keep, Outline, and Zammad remain external systems integrated via API/webhook.

```text
                     +-----------+
                     | Keycloak  |  OIDC
                     +-----+-----+
                           |
          +----------------+----------------+
          |                                 |
 +--------v---------+               +-------v-------+
 | oauth2-proxy     |               | Outline       |
 | (Keep SSO)       |               | (docs/wiki)   |
 +--------+---------+               +-------+-------+
          |                                 |
 +--------v---------+                       | S3 API
 | Keep             |                       v
 | backend/frontend |                    +--+----+
 +--------+---------+                    |Garage |
          |                              +-------+
          | webhook/API
 +--------v---------+
 | Owlstack         +-------> Zammad (ticket backend)
 | :8080            |
 +----+---------+---+
      |         |
      v         v
   PostgreSQL  Redis
```

## 1. Owlstack <-> Zammad

Zammad remains the ticket system of record.

- Owlstack reads/writes ticket data through Zammad APIs
- Owlstack stores metadata/SLA/linkage in its own database
- Zammad webhook events flow to Owlstack (`/api/v1/ticket-webhooks/*`) and are processed asynchronously

Values:

| Value | Description |
|---|---|
| `owlstack.config.zammadUrl` | Zammad service URL |
| `owlstack.secrets.zammadToken` | API token for Owlstack service user |

## 2. Owlstack <-> Outline

Outline is used for document workflows.

Used for:

- Ticket document search and linking
- Ticket suggestion panel
- Incident post-mortem document creation

Not used as a direct replacement for Owlstack's local runbook table. Owlstack still exposes `/api/v1/runbooks` for local runbook data.

Values:

| Value | Description |
|---|---|
| `owlstack.config.outlineUrl` | Outline public URL |
| `owlstack.secrets.outlineApiToken` | Outline API token |

## 3. Keep Integration Patterns

There are two valid flows in this stack:

### A) Vector -> Keep (ingestion into Keep)

- Vector HTTP sink posts to Keep backend (`/alerts/event`)
- Keep API key is provided from `keep-secrets`

### B) Keep -> Owlstack (incident creation in Owlstack)

- Keep workflow posts to Owlstack webhook (`/api/v1/webhooks/keep`)
- Owlstack performs correlation and optional incident creation

## 4. Owlstack <-> Keycloak (OIDC)

Owlstack uses OIDC authorization code flow.

| Value | Description |
|---|---|
| `owlstack.secrets.oidcIssuerUrl` | Realm issuer URL |
| `owlstack.secrets.oidcClientId` | Client ID |
| `owlstack.secrets.oidcClientSecret` | Client secret |
| `owlstack.secrets.sessionSecret` | Session signing secret |

## 5. Keep SSO via oauth2-proxy

Keep OSS is fronted by oauth2-proxy for Keycloak SSO.

Routing model:

- `/oauth2/*` -> oauth2-proxy
- `/` -> oauth2-proxy -> Keep frontend
- `/backend/*` -> Keep backend with `auth_request` header propagation
- `/websocket/*` -> Keep websocket service (required for realtime UI updates)

Key values:

| Value | Description |
|---|---|
| `keep.oauth2Proxy.enabled` | Enable proxy |
| `keep.oauth2Proxy.clientId` | Keycloak client ID |
| `keep.oauth2Proxy.issuerUrl` | OIDC issuer |
| `keep.oauth2Proxy.hostname` | Public Keep hostname |
| `keep.oauth2Proxy.cookieSecret` | Proxy cookie secret |
| `keep.oidcClientSecret` | OIDC client secret |

## 6. Outline OIDC + Garage S3

Outline authenticates directly to Keycloak and stores uploads in Garage.

Values:

| Value | Description |
|---|---|
| `outline.environment` | OIDC and S3 env vars |
| `outline.secrets.*` | DB/Redis/OIDC/S3 secrets |
| `garage.*` | Garage cluster and persistence settings |

## 7. Cross-Service Summary

| From | To | Method | Purpose |
|---|---|---|---|
| Owlstack | Zammad | REST API | Ticket CRUD/orchestration |
| Zammad | Owlstack | Webhook | Ticket event sync |
| Owlstack | Outline | REST API | Docs search/link + post-mortems |
| Vector | Keep | HTTP API | Alert ingestion |
| Keep | Owlstack | Webhook | Alert fan-out to incident pipeline |
| Owlstack | Keycloak | OIDC | User auth |
| Keep | Keycloak | OIDC via oauth2-proxy | User auth |
| Outline | Keycloak | OIDC | User auth |
| Outline | Garage | S3 API | File uploads |
