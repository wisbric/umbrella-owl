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
| `owlstack.config.outlineUrl` | Outline public URL |
| `owlstack.secrets.outlineApiToken` | Outline API token |

## 3. Keep Integration Patterns

There are two valid flows in this stack:

### A) Vector -> Keep (ingestion into Keep)

- Vector HTTP sink posts to Keep backend (`/alerts/event`)
- Keep API key is provided from `keep-secrets`

### B) Keep -> Owlstack (incident projection + enrichment)

- Keep workflow posts alert events to Owlstack webhook (`/api/v1/webhooks/keep`)
- Owlstack worker also polls Keep incidents via API for source-of-truth sync
- Keep-sourced incidents are read-only for core fields in Owlstack; Owlstack adds enrichment (runbook + post-mortem links, assignment metadata)

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
