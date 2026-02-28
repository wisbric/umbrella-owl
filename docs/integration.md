# Owl Ecosystem — Cross-Service Integration Specification

This document describes how NightOwl, BookOwl, and TicketOwl integrate with each other and with Zammad. It covers working flows, implementation gaps, and planned improvements.

---

## 1. Service Roles

| Service | Role | System of record for |
|---------|------|---------------------|
| **NightOwl** | Incident & on-call platform | Alerts, incidents, rosters, escalation policies |
| **BookOwl** | Knowledge management | Runbooks, post-mortems, documentation, templates |
| **TicketOwl** | Ticket orchestration | Ticket metadata, SLA state, auto-ticket rules |
| **Zammad** | Ticket engine (external) | Ticket content, articles, customer data, agents |

**Principle**: each service owns its domain data. Cross-service reads use REST APIs with tenant-scoped API keys. No service duplicates another's data — it fetches or caches it with short TTLs.

---

## 2. Authentication Between Services

All service-to-service calls use `X-API-Key` headers. Keys are tenant-scoped with `role=admin`.

| Direction | Env var / config | Dev key |
|-----------|-----------------|---------|
| NightOwl → BookOwl | Tenant config: `bookowl_api_url`, `bookowl_api_key` | `bw_dev_seed_key_do_not_use_in_production` |
| BookOwl → NightOwl | Tenant config: `nightowl_api_url`, `nightowl_api_key` | `ow_dev_seed_key_do_not_use_in_production` |
| TicketOwl → NightOwl | `integration_keys` table (encrypted) | `ow_dev_seed_key_do_not_use_in_production` |
| TicketOwl → BookOwl | `integration_keys` table (encrypted) | `bw_dev_seed_key_do_not_use_in_production` |
| TicketOwl → Zammad | `zammad_config` table (encrypted) | Per-instance Zammad API token |

Sidebar links (browser navigation between services) use public URLs configured via `NIGHTOWL_BOOKOWL_URL`, `BOOKOWL_NIGHTOWL_URL`, etc. and served through `/auth/config`.

---

## 3. Integration: NightOwl ↔ BookOwl

### 3.1 NightOwl fetches runbooks from BookOwl

**Status: Implemented (API working, UI wired)**

NightOwl proxies BookOwl's integration API through `/api/v1/bookowl/` so the NightOwl frontend can browse and search runbooks without direct BookOwl access.

**Flow:**
```
NightOwl frontend → GET /api/v1/bookowl/runbooks?q=crashloop
                  → NightOwl backend reads tenant config (bookowl_api_url, bookowl_api_key)
                  → GET {bookowl_api_url}/integration/runbooks?q=crashloop
                  ← BookOwl returns runbooks with title, tags, URL, content
                  ← NightOwl returns to frontend
```

**BookOwl endpoints consumed:**

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/api/v1/integration/runbooks` | List/search runbooks (query, limit, offset) |
| `GET` | `/api/v1/integration/runbooks/{id}` | Get single runbook (content_text + content_html) |
| `GET` | `/api/v1/integration/search` | Full-text search with score ranking |

**NightOwl proxy endpoints:**

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/api/v1/bookowl/status` | Check if BookOwl is configured (`integrated: bool`) |
| `GET` | `/api/v1/bookowl/runbooks` | Proxy to BookOwl runbook list |
| `GET` | `/api/v1/bookowl/runbooks/{id}` | Proxy to BookOwl single runbook |

**Key files:**
- `nightowl/pkg/bookowl/client.go` — HTTP client
- `nightowl/pkg/bookowl/handler.go` — proxy handlers
- `bookowl/internal/integration/handler.go` — integration endpoints

**Gap: Alert enrichment does not use BookOwl.** When alerts arrive via webhook, NightOwl only searches its local incidents table for matching runbooks. It never queries BookOwl, even when configured. This means runbooks authored in BookOwl are not surfaced during alert triage unless an operator manually searches.

### 3.2 BookOwl loads live context from NightOwl

**Status: Implemented (working)**

BookOwl documents can embed "live context blocks" — widgets that show real-time data from NightOwl (on-call roster, active alerts, incident status). The BookOwl backend proxies these requests to NightOwl with Redis caching.

**Flow:**
```
BookOwl editor renders live-context block
  → GET /api/v1/live-context/oncall/{rosterId}
  → BookOwl checks Redis cache (key: live-context:{tenant}:oncall:{rosterId})
    → If fresh (<30s): return cached, source="cache"
    → If miss/stale: call NightOwl GET /api/v1/rosters/{id}/oncall
      → Success: cache 5min, return source="live"
      → Fail + stale cache exists: return stale, source="stale"
      → Fail + no cache: return source="unavailable"
```

**Live context endpoints (BookOwl → NightOwl):**

| BookOwl path | NightOwl path | Data |
|-------------|---------------|------|
| `/api/v1/live-context/oncall/{rosterId}` | `/api/v1/rosters/{id}/oncall` | Primary/secondary on-call, shift end |
| `/api/v1/live-context/service/{serviceName}` | `/api/v1/alerts?status=firing&service_name={name}` | Firing alerts for a service |
| `/api/v1/live-context/alerts` | `/api/v1/alerts?status=firing&severity=critical,major` | Active critical/major alerts |
| `/api/v1/live-context/incident/{incidentId}` | `/api/v1/incidents/{id}` | Incident details |

**Key files:**
- `bookowl/pkg/livecontext/client.go` — NightOwl HTTP client
- `bookowl/pkg/livecontext/handler.go` — proxy handlers
- `bookowl/pkg/livecontext/cache.go` — Redis caching (30s fresh, 5min stale)

### 3.3 Post-mortem generation from incidents

**Status: Backend implemented, not wired into incident resolution UI**

When an incident is resolved in NightOwl, a post-mortem document should be created in BookOwl pre-filled with incident details (timeline, root cause, resolution, severity).

**Intended flow:**
```
1. Incident resolved in NightOwl
2. User clicks "Create Post-Mortem" (not yet in UI)
3. NightOwl frontend → POST /api/v1/bookowl/post-mortems
4. NightOwl backend → POST {bookowl_api_url}/integration/post-mortems
   Payload: { title, space_slug: "post-mortems", incident: { id, title, severity, root_cause, solution, created_at, resolved_at, resolved_by } }
5. BookOwl creates document from template with variable substitution
6. BookOwl returns { id, url, title }
7. NightOwl stores URL (not yet implemented — needs incidents.post_mortem_url column)
8. Frontend shows "View Post-Mortem" link
```

**Post-mortem template sections** (Tiptap JSON, built in `bookowl/internal/integration/postmortem.go`):
- Incident title, date, severity, resolved by
- Summary (from root cause)
- Timeline placeholder
- Root Cause (from incident data)
- Impact placeholder
- Action Items (task list)
- Lessons Learned placeholder

**BookOwl endpoint:**

| Method | Path | Purpose |
|--------|------|---------|
| `POST` | `/api/v1/integration/post-mortems` | Create post-mortem from incident data |

Response: `201 { id, url, title }`

The document is created with `doc_type=post-mortem`, `status=published`, tags `["post-mortem", severity]`, and the NightOwl incident ID stored in `documents.nightowl_incident_id` for bidirectional linking.

**Gaps:**
- No "Create Post-Mortem" button in NightOwl incident resolution UI
- No `incidents.post_mortem_url` column to store the result
- No deduplication (should check if post-mortem already exists for incident)
- Template is fetched from DB (`doc_type=post-mortem`) with hardcoded fallback — no admin UI to customize templates

---

## 4. Integration: TicketOwl ↔ Zammad

### 4.1 Architecture

TicketOwl is a **thin orchestration layer** over Zammad. It never stores ticket content — only metadata, links, and SLA state. All ticket reads go through Zammad's REST API; writes go to Zammad and TicketOwl tracks the result.

**Status: Client implemented, worker partially wired**

### 4.2 Zammad client

**Location:** `ticketowl/internal/zammad/`

**Capabilities:**
- Ticket CRUD (`ListTickets`, `GetTicket`, `CreateTicket`, `UpdateTicket`, `SearchTickets`)
- Article (comment) CRUD (`ListArticles`, `CreateArticle`)
- State/priority lookups with Redis caching (1h TTL)
- User and organization operations
- Retry with exponential backoff (3 attempts, 250ms base, 2x multiplier, ±20% jitter)
- Never retries client errors (400, 401, 403, 404, 422)

**Auth:** `Authorization: Token token={api_token}` — token stored per-tenant in `zammad_config` table, encrypted AES-256-GCM.

### 4.3 Webhook sync (Zammad → TicketOwl)

**Status: Handler implemented, event processing skeleton only**

Zammad fires webhooks to `POST /api/v1/webhooks/zammad` on ticket/article events. TicketOwl validates the HMAC-SHA1 signature, pushes to a Redis stream, and returns 200 immediately. A worker process consumes events asynchronously.

**Events handled:**

| Event | Worker action | Status |
|-------|--------------|--------|
| `ticket.create` | Upsert `ticket_meta`, assign SLA policy, init SLA state | Skeleton (logs only) |
| `ticket.update` | Check pause status, recompute SLA | Skeleton (logs only) |
| `article.create` | Reserved for notification hooks | Not implemented |

**Webhook security:** HMAC-SHA1 via `X-Hub-Signature` header. Secret stored in `zammad_config.webhook_secret` (encrypted).

### 4.4 SLA management

**Status: Pure computation implemented, worker polling skeleton**

TicketOwl tracks SLA state independently from Zammad. Each ticket gets an SLA policy based on priority, and a state machine tracks response/resolution deadlines.

**State machine:**
```
on_track → warning (< threshold remaining) → breached (deadline passed)
                                            ↓
                                    NightOwl alert fired (once)

Any state → met (both response + resolution before deadline)
Any state → paused (ticket in pause status, e.g. "pending customer")
```

**SLA defaults:**

| Priority | Response | Resolution | Warning threshold |
|----------|----------|------------|-------------------|
| Critical | 30 min | 4 hours | 20% remaining |
| High | 1 hour | 8 hours | 20% remaining |
| Normal | 4 hours | 24 hours | 20% remaining |
| Low | 8 hours | 48 hours | 20% remaining |

**SLA poller** (`ticketowl/internal/worker/slapoller.go`): runs every 60 seconds, checks `on_track`/`warning` SLA states, fetches current Zammad ticket state, handles pause/resume, and fires NightOwl alerts on first breach.

**Key files:**
- `ticketowl/internal/sla/service.go` — `ComputeState()` pure function (fully tested)
- `ticketowl/internal/worker/slapoller.go` — polling loop
- `ticketowl/internal/notification/service.go` — `AlertSLABreach()` → NightOwl alert

### 4.5 Connection test

```
POST /api/v1/admin/config/zammad/test
  → GET {zammad_url}/api/v1/users/me
  ← { ok: true, zammad_version, agent_name, agent_email }
```

---

## 5. Integration: TicketOwl ↔ NightOwl

### 5.1 Incident → Ticket auto-creation

**Status: Rule matching implemented, Zammad ticket creation not wired**

When NightOwl fires an `incident.created` webhook, TicketOwl evaluates auto-ticket rules and creates Zammad tickets for matching incidents.

**Flow:**
```
NightOwl → POST /api/v1/webhooks/nightowl { event: "incident.created", ... }
  → TicketOwl pushes to Redis stream
  → Worker evaluates auto_ticket_rules:
      - alert_group match (exact or prefix, e.g. "kubernetes-")
      - severity >= min_severity
  → For each matching rule:
      - Render title from template ({{.AlertName}}, {{.Summary}}, {{.Service}}, {{.Severity}})
      - Create Zammad ticket (group, priority from rule)
      - Store ticket_meta + incident_link
      - Init SLA state
```

**Auto-ticket rule schema:**
```sql
name              TEXT
enabled           BOOLEAN
alert_group       TEXT        -- exact or prefix match (trailing "-")
min_severity      TEXT        -- threshold: low|medium|high|critical
default_priority  TEXT        -- Zammad priority for created tickets
default_group     TEXT        -- Zammad group
title_template    TEXT        -- Go template syntax
```

### 5.2 Incident resolution → Ticket closure

**Status: Not wired**

When NightOwl fires `incident.resolved`, TicketOwl should find all linked tickets and close them in Zammad.

**Intended flow:**
```
NightOwl → POST /api/v1/webhooks/nightowl { event: "incident.resolved", ... }
  → Worker finds incident_links WHERE incident_id = event.IncidentID
  → For each linked ticket:
      - Fetch Zammad ticket state
      - If not closed: update to closed
      - Record resolution_met_at in sla_states
```

### 5.3 SLA breach → NightOwl alert (escalation)

**Status: Implemented**

When an SLA breaches for the first time, TicketOwl creates an alert in NightOwl to page the on-call engineer.

```
SLA poller detects breach (first_breach_alerted_at IS NULL)
  → POST {nightowl_api_url}/api/v1/alerts
    {
      name: "SLA Breach",
      summary: "Ticket #1234 has breached SLA (resolution, critical priority)",
      severity: "high",
      labels: { source: "ticketowl", ticket_id, ticket_number, sla_type, priority }
    }
  → NightOwl creates incident → pages on-call
  → TicketOwl sets first_breach_alerted_at (prevents duplicate alerts)
```

### 5.4 On-call display on ticket detail

**Status: Client implemented, UI not built**

The ticket detail page fetches the current on-call person from NightOwl for the ticket's linked incident service. Fetched live (no caching).

```
Ticket detail page loads
  → GET on-call for linked incident's service
  → NightOwl: GET /api/v1/oncall/{service}
  ← { user_name, user_email, shift_end }
  → Displayed in sidebar widget
  → If unavailable: widget hidden gracefully
```

---

## 6. Integration: TicketOwl ↔ BookOwl

### 6.1 Runbook suggestions on ticket detail

**Status: Client implemented, UI not built**

When viewing a ticket, TicketOwl searches BookOwl for relevant runbooks/articles based on the ticket's title and tags.

```
Ticket detail page loads
  → GET /api/v1/tickets/{id}/suggestions
  → TicketOwl calls BookOwl: GET /api/v1/articles/search?query={title}&tags={tags}&limit=5
  ← Up to 5 article summaries (id, title, excerpt, url)
  → Displayed in sidebar
  → If BookOwl unreachable: empty list + log (graceful degradation)
```

### 6.2 Article linking

**Status: Backend implemented, UI not built**

Agents can link BookOwl articles to tickets. Links are stored in `article_links` with snapshot metadata (slug, title) and visible to both agents and customers.

### 6.3 Post-mortem creation from ticket

**Status: Client implemented, UI not built**

Agents can create a BookOwl post-mortem from a ticket, pre-filled with linked incident data.

```
Agent clicks "Create Post-Mortem" on ticket
  → POST /api/v1/tickets/{id}/postmortem
  → TicketOwl fetches linked incidents from NightOwl
  → Calls BookOwl: POST /api/v1/postmortems
    { title, ticket_id, ticket_number, incident_ids, summary, tags }
  ← { id, url }
  → Stored in postmortem_links (deduplicated — 409 if exists)
  → URL returned to frontend
```

---

## 7. Integration: Zammad ↔ On-Call (Roster)

### 7.1 Current state

Roster data lives in NightOwl. TicketOwl fetches on-call info live from NightOwl for display purposes only. Zammad has no awareness of rosters or on-call schedules.

### 7.2 Problem

When a support ticket arrives in Zammad, there is no automatic routing based on who is on-call. Agents must manually check NightOwl to find the on-call engineer. SLA breach escalation goes through NightOwl alerts, but there is no way for Zammad to assign tickets directly to the on-call person.

### 7.3 Proposed improvement: On-call ticket assignment

TicketOwl could act as the bridge between Zammad's ticket assignment and NightOwl's roster system.

**Option A: Auto-assign on ticket creation**

When a Zammad ticket is created (via webhook or auto-ticket rule), TicketOwl could:
1. Determine the relevant service/roster from the ticket's group or tags
2. Fetch the current on-call person from NightOwl
3. Look up the on-call person's Zammad user ID (by email match)
4. Update the Zammad ticket's `owner_id` to the on-call agent

This requires:
- A mapping from Zammad groups → NightOwl roster IDs (new config: `group_roster_mappings` table)
- Zammad user lookup by email (`ticketowl/internal/zammad/users.go` — already exists)
- Auto-assign logic in the event handler

**Option B: Roster-aware SLA escalation**

Instead of (or in addition to) alerting via NightOwl, TicketOwl could:
1. On SLA warning: assign ticket to current on-call in Zammad
2. On SLA breach: escalate to secondary on-call
3. Include roster shift info in the SLA breach alert

This requires:
- NightOwl roster API to expose both primary and secondary on-call
- TicketOwl to map on-call users to Zammad agents

**Option C: Periodic roster sync to Zammad groups**

TicketOwl could periodically sync NightOwl roster assignments to Zammad group membership, so Zammad's native round-robin assignment routes tickets to on-call agents.

This is the heaviest approach and couples Zammad's group model tightly to NightOwl's roster model. Not recommended unless Zammad's native assignment features are needed.

**Recommendation: Option A + B combined**

- Auto-assign new tickets to on-call (Option A) handles the happy path
- Roster-aware escalation (Option B) handles SLA breaches
- Both use existing APIs — NightOwl already exposes on-call data, Zammad already supports owner updates
- New config: mapping table linking Zammad groups to NightOwl roster IDs

**Schema for group-roster mapping:**
```sql
CREATE TABLE group_roster_mappings (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    zammad_group    TEXT NOT NULL,           -- Zammad group name (e.g. "kubernetes")
    roster_id       TEXT NOT NULL,           -- NightOwl roster ID
    auto_assign     BOOLEAN NOT NULL DEFAULT true,  -- auto-assign tickets to on-call
    escalate_to_secondary BOOLEAN NOT NULL DEFAULT true,  -- use secondary on SLA breach
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (zammad_group)
);
```

**Implementation steps:**
1. Add `group_roster_mappings` migration to TicketOwl
2. Add admin UI for mapping Zammad groups to rosters
3. In auto-ticket event handler: after creating Zammad ticket, look up roster mapping, fetch on-call, assign
4. In SLA breach handler: look up roster mapping, fetch on-call, update Zammad ticket owner, include on-call info in NightOwl alert

---

## 8. Data Flow Diagrams

### 8.1 Incident lifecycle (full cross-service flow)

```
Alert arrives (Alertmanager, Prometheus, etc.)
  │
  ▼
┌─────────────────────────────────────────────────────────────────────┐
│ NightOwl                                                            │
│   1. Webhook receives alert                                         │
│   2. Alert enriched from local KB (gap: should also query BookOwl)  │
│   3. Incident created if new fingerprint                            │
│   4. On-call paged via Slack/Mattermost/Twilio                      │
│   5. Webhook fires: incident.created → TicketOwl                    │
│                                                                     │
│   ... incident worked ...                                           │
│                                                                     │
│   6. Incident resolved                                              │
│   7. Webhook fires: incident.resolved → TicketOwl                   │
│   8. User clicks "Create Post-Mortem" → BookOwl                     │
└─────────┬──────────────────────────────────┬───────────────────┬────┘
          │ incident.created                  │ incident.resolved │ POST post-mortem
          ▼                                   ▼                   ▼
┌─────────────────────────────┐   ┌──────────────────────────────────┐
│ TicketOwl                   │   │ BookOwl                          │
│  1. Evaluate auto-ticket    │   │  1. Create post-mortem document  │
│     rules                   │   │  2. Pre-fill from incident data  │
│  2. Create Zammad ticket    │   │  3. Return URL to NightOwl       │
│  3. Init SLA tracking       │   │                                  │
│  4. Link ticket↔incident    │   │  Live context blocks in docs:    │
│                             │   │  - On-call roster widget         │
│  ... SLA monitored ...      │   │  - Active alerts widget          │
│                             │   │  - Incident status widget        │
│  On breach:                 │   │  (proxied from NightOwl, cached) │
│  5. Alert NightOwl          │   │                                  │
│  6. Page on-call            │   └──────────────────────────────────┘
│                             │
│  On incident.resolved:      │
│  7. Close Zammad ticket     │
│  8. Record resolution       │
└──────────┬──────────────────┘
           │ Create/Update ticket
           ▼
┌──────────────────────────────┐
│ Zammad                       │
│  Ticket engine (content,     │
│  articles, customer comms)   │
│  Webhook → TicketOwl on      │
│  ticket/article events       │
└──────────────────────────────┘
```

### 8.2 SLA breach escalation

```
TicketOwl SLA poller (every 60s)
  │
  │  Detects: state changed to "breached", first_breach_alerted_at IS NULL
  │
  ▼
POST NightOwl /api/v1/alerts
  { name: "SLA Breach", severity: "high", labels: { source: ticketowl, ... } }
  │
  ▼
NightOwl creates incident → pages on-call
  │
  ▼
On-call engineer responds → works ticket in Zammad
  │
  ▼
Zammad ticket updated → webhook → TicketOwl → SLA state updated
```

---

## 9. Implementation Status

### Working

| Integration | Direction | Status |
|------------|-----------|--------|
| Runbook browsing/search | NightOwl → BookOwl | Working |
| Live context (on-call, alerts, incidents) | BookOwl → NightOwl | Working |
| Post-mortem creation API | NightOwl → BookOwl | API working, UI not wired |
| SLA breach alerting | TicketOwl → NightOwl | Working |
| Zammad REST client | TicketOwl → Zammad | Working |
| Zammad webhook receiver | Zammad → TicketOwl | Handler working, processing skeleton |
| NightOwl webhook receiver | NightOwl → TicketOwl | Handler working, processing skeleton |
| Auto-ticket rule matching | TicketOwl internal | Logic done, Zammad create not wired |
| SLA computation | TicketOwl internal | Pure function fully tested |
| Cross-service sidebar links | All services | Working (via /auth/config) |
| Integration URL placeholders | All admin pages | Working (via /auth/config) |

### Not wired / gaps

| Gap | Services | Impact | Effort |
|-----|----------|--------|--------|
| Post-mortem button in incident resolution UI | NightOwl | Users must manually create post-mortems | Small — add button + call existing proxy endpoint |
| `incidents.post_mortem_url` column | NightOwl | Can't link back from incident to post-mortem | Small — migration + store update |
| Alert enrichment from BookOwl | NightOwl | Runbooks from BookOwl not surfaced during alert triage | Medium — add BookOwl search fallback in `alert/enrich.go` |
| Worker event handlers (DB ops) | TicketOwl | Zammad tickets not auto-created/closed from incidents | Medium — wire existing matching logic to Zammad client |
| SLA poller Zammad integration | TicketOwl | SLA state not updated from Zammad status changes | Medium — add Zammad fetch in poller loop |
| Agent ticket detail UI | TicketOwl | No UI for enriched ticket view, suggestions, on-call | Large — full frontend page |
| Customer portal UI | TicketOwl | No customer-facing ticket view | Large — full frontend section |
| On-call auto-assignment in Zammad | TicketOwl | Tickets not routed to on-call agent | Medium — see section 7.3 |
| Runbook migration command | BookOwl | No way to import NightOwl runbooks | Medium — CLI command, one-time |
| NightOwl runbook deprecation | NightOwl | Duplicate runbook systems | Large — requires migration path |
| Slack runbook search via BookOwl | NightOwl | `/nightowl runbook` doesn't search BookOwl | Small — add BookOwl client call in Slack handler |

---

## 10. Configuration Reference

### Environment variables (cross-service URLs)

| Variable | Service | Purpose |
|----------|---------|---------|
| `NIGHTOWL_BOOKOWL_URL` | NightOwl | BookOwl web URL (sidebar link) |
| `NIGHTOWL_TICKETOWL_URL` | NightOwl | TicketOwl web URL (sidebar link) |
| `NIGHTOWL_BOOKOWL_API_URL` | NightOwl | BookOwl API URL (integration placeholder) |
| `BOOKOWL_NIGHTOWL_URL` | BookOwl | NightOwl web URL (sidebar link) |
| `BOOKOWL_TICKETOWL_URL` | BookOwl | TicketOwl web URL (sidebar link) |
| `BOOKOWL_NIGHTOWL_API_URL` | BookOwl | NightOwl API URL (live context) |
| `TICKETOWL_NIGHTOWL_URL` | TicketOwl | NightOwl web URL (sidebar link) |
| `TICKETOWL_BOOKOWL_URL` | TicketOwl | BookOwl web URL (sidebar link) |
| `TICKETOWL_NIGHTOWL_API_URL` | TicketOwl | NightOwl API URL (incidents, alerts, on-call) |
| `TICKETOWL_BOOKOWL_API_URL` | TicketOwl | BookOwl API URL (runbooks, post-mortems) |

### Tenant-level config (stored in DB, set via admin UI)

| Service | Config table | Fields |
|---------|-------------|--------|
| NightOwl | `tenant_config` (JSONB) | `bookowl_api_url`, `bookowl_api_key` |
| BookOwl | `admin_config` | `nightowl_api_url`, `nightowl_api_key` |
| TicketOwl | `integration_keys` | NightOwl + BookOwl: `api_url`, `api_key` (encrypted) |
| TicketOwl | `zammad_config` | `url`, `api_token`, `webhook_secret`, `pause_statuses` (encrypted) |

### Helm values (lab environment)

```yaml
nightowl:
  config:
    bookowlUrl: "https://bookowl.devops.lab"
    ticketowlUrl: "https://ticketowl.devops.lab"
    bookowlApiUrl: "http://owl-bookowl-api:8081/api/v1"

bookowl:
  nightowl:
    apiUrl: "http://owl-nightowl:80"
    url: "https://nightowl.devops.lab"
  ticketowl:
    url: "https://ticketowl.devops.lab"

ticketowl:
  config:
    nightowlApiUrl: "http://owl-nightowl:80"
    bookowlApiUrl: "http://owl-bookowl-api:8081"
    nightowlUrl: "https://nightowl.devops.lab"
    bookowlUrl: "https://bookowl.devops.lab"
```

---

## 11. Testing Strategy

### Unit tests (per-service)

Each service's integration client has a mock server (`mock_test.go` using `httptest`). Pure functions (SLA computation, auto-ticket rule matching, template rendering) are tested with table-driven tests. No real external services in unit tests.

### Integration tests (planned)

| Test | Services | Approach |
|------|----------|----------|
| NightOwl → BookOwl runbook fetch | NightOwl + BookOwl | testcontainers (both DBs) + real HTTP |
| Post-mortem creation | NightOwl + BookOwl | testcontainers + verify document created |
| Incident → auto-ticket | TicketOwl + mock NightOwl + mock Zammad | testcontainers (TicketOwl DB) + httptest mocks |
| SLA breach → alert | TicketOwl + mock NightOwl | testcontainers + verify alert payload |
| Zammad webhook → SLA update | TicketOwl + mock Zammad | testcontainers + verify state transition |

### Manual verification checklist

1. NightOwl admin: configure BookOwl API URL + key → test connection → browse runbooks
2. BookOwl admin: configure NightOwl API URL + key → test connection → add live context block to document
3. NightOwl: resolve incident → create post-mortem → verify document in BookOwl
4. TicketOwl admin: configure Zammad + NightOwl + BookOwl → test all connections
5. NightOwl: create incident → verify TicketOwl auto-creates Zammad ticket
6. Zammad: update ticket → verify SLA state changes in TicketOwl
7. TicketOwl: SLA breach → verify NightOwl alert + on-call paged
8. Sidebar: verify cross-service links render in all three services
