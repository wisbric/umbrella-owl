# Operator Design — OwlStack Operator

> **Status:** Design-only. Implementation deferred — the umbrella chart + ArgoCD is sufficient for current scale.

## Overview

An operator would replace the umbrella Helm chart with a declarative CRD that manages the entire owl ecosystem lifecycle. This document scopes what the operator would manage and how it would be structured.

## CRD: `OwlStack` (owlstack.wisbric.com/v1alpha1)

```yaml
apiVersion: owlstack.wisbric.com/v1alpha1
kind: OwlStack
metadata:
  name: owl
  namespace: owl
spec:
  domain: devops.lab

  owlstack:
    enabled: true
    version: "0.4.0"
    replicas:
      api: 2
      worker: 1

  keep:
    enabled: true
    version: "0.1.94"
    auth: oauth2proxy

  outline:
    enabled: true
    version: "2.2.2"
    storage: garage

  keycloak:
    enabled: true
    realm: owls
    clients:
      - nightowl
      - keep
      - outline

  postgresql:
    enabled: true
    databases:
      - name: nightowl
        owner: nightowl
      - name: keycloak
        owner: keycloak
      - name: zammad
        owner: zammad
      - name: keep
        owner: keep
      - name: outline
        owner: outline

  redis:
    enabled: true

  zammad:
    enabled: true

  garage:
    enabled: true
    replicationFactor: 1

status:
  phase: Ready  # Ready | Degraded | Failed
  components:
    owlstack: Ready
    keep: Ready
    outline: Ready
    keycloak: Ready
    postgresql: Ready
    redis: Ready
    zammad: Ready
    garage: Ready
  observedGeneration: 3
  lastReconcileTime: "2026-03-04T12:00:00Z"
```

## What the Operator Manages

### 1. Helm Release Lifecycle

Install, upgrade, and rollback all subcharts using the Helm Go SDK. Each component maps to a Helm release. The operator watches the `OwlStack` CR and reconciles Helm releases to match the desired state.

### 2. Database Provisioning

Automatically create PostgreSQL databases and users when a component is enabled. Uses a PostgreSQL connection to execute `CREATE DATABASE` / `CREATE USER` / `GRANT` statements. Replaces the current `initdb.scripts` approach which only runs on fresh installs.

### 3. Keycloak Realm/Client Automation

Automatically create and update Keycloak OIDC clients when components are enabled. Uses the Keycloak Admin API to:
- Create the `owls` realm (if not exists)
- Create/update client configurations for each enabled component
- Rotate client secrets on demand
- Configure redirect URIs based on `spec.domain`

### 4. Health Monitoring + Status Reporting

Continuously monitor component health and update `status.components`. Checks include:
- Pod readiness
- Service endpoint health
- Database connectivity
- Keycloak realm accessibility
- S3 bucket availability (Garage)

### 5. Secret Rotation

Rotate secrets on a configurable schedule:
- Database passwords
- OIDC client secrets
- Session secrets / encryption keys
- oauth2-proxy cookie secrets
- Garage access keys

### 6. Backup Orchestration

Manage pg_dump CronJobs for each database:
- Create CronJobs based on `spec.postgresql.databases`
- Upload backups to Garage S3
- Retention policy (keep N backups)
- Point-in-time restore workflow

## Repository

Separate repo: `github.com/wisbric/owlstack-operator`

Scaffold: kubebuilder v4

```
owlstack-operator/
├── api/v1alpha1/
│   └── owlstack_types.go       # CRD type definitions
├── internal/controller/
│   └── owlstack_controller.go  # Main reconciliation loop
├── internal/helm/
│   └── releases.go             # Helm SDK wrapper
├── internal/database/
│   └── provisioner.go          # PostgreSQL DB/user management
├── internal/keycloak/
│   └── client.go               # Keycloak Admin API client
├── internal/health/
│   └── checker.go              # Component health monitoring
├── config/
│   ├── crd/                    # Generated CRD manifests
│   ├── rbac/                   # RBAC rules
│   └── manager/                # Deployment manifests
└── Makefile
```

## Implementation Phases

| Phase | Scope | Effort |
|-------|-------|--------|
| A | Scaffold + CRD + basic Helm reconciliation | 1-2 weeks |
| B | Database provisioning (create DBs + users) | 1 week |
| C | Keycloak automation (realm + clients) | 1-2 weeks |
| D | Health monitoring + status reporting | 1 week |
| E | Backup/restore orchestration | 1-2 weeks |

## Decision

**Deferred.** The umbrella Helm chart + ArgoCD covers current needs:

- Single installation (lab + one production)
- Manual but infrequent operations (database creation, Keycloak client setup)
- ArgoCD handles drift detection and sync

**When to reconsider:**
- Managing 3+ installations across environments
- Day-2 operations (secret rotation, backup management) become too manual
- Need for automated database provisioning on component enable/disable
- Want self-healing beyond what ArgoCD provides
