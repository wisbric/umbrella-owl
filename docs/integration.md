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
- Incident runbook linking (`/api/v1/runbooks` is Outline-backed)

Values:

| Value | Description |
|---|---|
| `owlstack.config.outlineUrl` | Outline URL (use internal `http://owl-outline:8081` to avoid hairpin NAT) |
| `owlstack.secrets.outlineApiToken` | Outline API token (`ol_api_*` JWT format — must be created via Outline's `/api/apiKeys.create` endpoint) |

> **Note:** Outline API tokens are JWTs (`ol_api_*` prefix), not raw secrets. They must be created
> through Outline's API with a valid session, not by manual DB insert. The ESO mapping pulls from
> `platform/owl/owlstack.outline-api-token` in OpenBao.

> **Note:** `FORCE_HTTPS=false` must be set on the Outline deployment when using internal HTTP URLs.
> Outline 1.3.0+ defaults to `FORCE_HTTPS=true` which returns HTTP 405 for internal POST requests.

## 3. Keep Integration Patterns

There are two valid flows in this stack:

### A) Vector -> Keep (ingestion into Keep)

- Vector HTTP sink posts to Keep backend (`/alerts/event`)
- Keep API key is provided from `keep-secrets`

### B) Keep -> Owlstack (incident projection + enrichment)

- Keep workflow posts alert events to Owlstack webhook (`/api/v1/webhooks/keep`)
- Owlstack worker also polls Keep incidents via API for source-of-truth sync
- Keep-sourced incidents are read-only for core fields in Owlstack; Owlstack adds enrichment (runbook + post-mortem links, assignment metadata)

> **API key distinction:** Keep has two API keys in OpenBao (`platform/owl/keep`):
> - `api-key` — Vector webhook ingestion key (`KEEP_API_KEY`)
> - `admin-api-key` — Owlstack admin access key (`OWLSTACK_KEEP_API_KEY` in ESO)

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

Routing model (nginx `auth_request` pattern — requires Keep >= 0.49.0):

- `/oauth2/*` -> oauth2-proxy (login/callback/auth validation only)
- `/` -> Keep frontend directly (nginx validates via `auth_request` to `/oauth2/auth`, forwards identity headers)
- `/backend/*`, `/websocket/*` -> Keep backend/websocket (nginx validates via `auth_request`, forwards identity headers)

> **Note:** nginx `proxy-buffer-size: 16k` is required on the oauth2-proxy ingress because
> Keycloak session cookies exceed the default 4KB buffer, causing 502 on oauth2 callback.

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
| Keep | Owlstack | Webhook + poller | Alert fan-out + incident sync |
| Owlstack | Keycloak | OIDC | User auth |
| Keep | Keycloak | OIDC via oauth2-proxy | User auth |
| Outline | Keycloak | OIDC | User auth |
| Outline | Garage | S3 API | File uploads |

## 8. MCP Servers (AI Agent Integration)

The platform supports Model Context Protocol (MCP) servers for AI agent interaction.
All MCP servers are optional and gated by `mcpServers.{service}.enabled`.

| MCP Server | Image | Port | Purpose |
|---|---|---|---|
| owlstack-mcp | owlstack binary (`APP_MODE=mcp`) | 8081 | Owlstack tools (alerts, incidents, rosters, escalation, users) |
| keep-mcp | `registry.gitlab.com/adfinisde/agentic-workspace/ai-ops/keep-mcp` | 8082 | Keep alert/incident management |
| mcp-k8s | `ghcr.io/containers/kubernetes-mcp-server` | 8083 | K8s cluster read-only access |
| mcp-postgres | Anthropic official | 3000 | PostgreSQL read-only SQL |

### Owlstack MCP Gateway

When `OWLSTACK_MCP_BACKENDS` is set (comma-separated `name=url` pairs), the owlstack MCP server
also serves a gateway discovery endpoint at `/.well-known/mcp.json` listing all backend MCP servers,
and a `/status` endpoint for backend health checking.

Example config:
```
OWLSTACK_MCP_BACKENDS=keep=http://owl-mcp-keep:8082,k8s=http://owl-mcp-k8s:8083
```
