#!/usr/bin/env bash
# =============================================================================
# setup-zammad.sh — One-time Zammad provisioning for running lab environment
# =============================================================================
# Creates admin user, service user, API token, sample data in Zammad,
# then updates TicketOwl's zammad_config in the database.
#
# Usage:
#   ./deploy/setup-zammad.sh
#
# Prerequisites:
#   - kubectl configured for the lab cluster
#   - Zammad pod running: owl-zammad-0 -c zammad-railsserver
#   - PostgreSQL pod running: owl-postgresql-0
# =============================================================================
set -euo pipefail

NAMESPACE="${NAMESPACE:-owl}"
ZAMMAD_POD="owl-zammad-0"
ZAMMAD_CONTAINER="zammad-railsserver"
PG_POD="owl-postgresql-0"

# Pre-generated token (must match values.lab-secrets.yaml)
TICKETOWL_TOKEN="75cdbbcbd8a9123fff7ab100f8391ee0a55bd94466102796424b1d4a5c2ecf25"

# TicketOwl DB password (from values.lab-secrets.yaml)
TICKETOWL_DB_PASS="${TICKETOWL_DB_PASS:-M7ov36EIDVFFFE5xDqZSXZH7Wn0cH8O5}"

echo "=== Step 1: Create admin + service user + API token + sample data in Zammad ==="

kubectl exec -n "$NAMESPACE" "$ZAMMAD_POD" -c "$ZAMMAD_CONTAINER" -- rails runner '
  # --- Admin user ---
  admin = User.find_by(login: "admin@wisbric.local")
  unless admin
    admin = User.create!(
      login:     "admin@wisbric.local",
      firstname: "Admin",
      lastname:  "Wisbric",
      email:     "admin@wisbric.local",
      password:  "OwlAdmin2026!",
      active:    true,
      verified:  true,
      roles:     Role.where(name: %w[Admin Agent]),
      updated_by_id: 1,
      created_by_id: 1,
    )
    puts "Created admin user: #{admin.login}"
  else
    puts "Admin user already exists: #{admin.login}"
  end

  # --- Service user ---
  svc = User.find_by(login: "ticketowl-service")
  unless svc
    svc = User.create!(
      login:     "ticketowl-service",
      firstname: "TicketOwl",
      lastname:  "Service",
      email:     "ticketowl-service@wisbric.local",
      password:  "TicketOwlService2026!",
      active:    true,
      verified:  true,
      roles:     Role.where(name: %w[Admin Agent]),
      updated_by_id: 1,
      created_by_id: 1,
    )
    puts "Created service user: #{svc.login}"
  else
    puts "Service user already exists: #{svc.login}"
  end

  # --- API token ---
  token_name = "TicketOwl Integration"
  existing = Token.find_by(user_id: svc.id, name: token_name)
  unless existing
    Token.create!(
      user_id:    svc.id,
      name:       token_name,
      action:     "api",
      persistent: true,
      token:      ENV.fetch("TICKETOWL_TOKEN", "'"$TICKETOWL_TOKEN"'"),
    )
    puts "Created API token: #{token_name}"
  else
    puts "API token already exists: #{token_name}"
  end

  # --- Groups ---
  %w[Support Engineering Billing].each do |name|
    unless Group.find_by(name: name)
      Group.create!(name: name, active: true, updated_by_id: 1, created_by_id: 1)
      puts "Created group: #{name}"
    end
  end

  # --- Organizations ---
  ["Acme Corp", "Wisbric"].each do |name|
    unless Organization.find_by(name: name)
      Organization.create!(name: name, active: true, updated_by_id: 1, created_by_id: 1)
      puts "Created organization: #{name}"
    end
  end

  # --- Sample tickets ---
  support = Group.find_by(name: "Support") || Group.first
  eng     = Group.find_by(name: "Engineering") || Group.first
  billing = Group.find_by(name: "Billing") || Group.first

  prio_low    = Ticket::Priority.find_by(name: "1 low")
  prio_normal = Ticket::Priority.find_by(name: "2 normal")
  prio_high   = Ticket::Priority.find_by(name: "3 high")

  state_open    = Ticket::State.find_by(name: "open")
  state_pending = Ticket::State.find_by(name: "pending reminder") || Ticket::State.find_by(name: "pending close") || state_open
  state_closed  = Ticket::State.find_by(name: "closed")

  tickets = [
    { title: "Login page returns 500 after upgrade",
      group: support, priority: prio_high, state: state_open,
      body: "After the v2.4.1 upgrade, the /login endpoint returns a 500 Internal Server Error for all users. Stack trace points to a nil pointer in the session middleware. This is blocking all customer logins." },
    { title: "API rate limiting not working",
      group: eng, priority: prio_normal, state: state_open,
      body: "Rate limiting middleware is configured for 100 req/min but load testing shows no throttling even at 500 req/min. Checked nginx config and the X-RateLimit headers are missing from responses." },
    { title: "Invoice PDF generation broken",
      group: billing, priority: prio_high, state: state_open,
      body: "PDF generation for invoices fails with a wkhtmltopdf timeout. Affects all invoices created after 2026-02-15. The HTML template renders correctly in browser but the PDF converter hangs." },
    { title: "Dashboard widget not loading for IE users",
      group: support, priority: prio_low, state: state_closed,
      body: "Legacy IE11 users report the analytics dashboard widget shows a blank white box. Root cause was an unsupported ES2020 optional chaining operator. Fixed by adding the Babel plugin." },
    { title: "Database connection pool exhausted under load",
      group: eng, priority: prio_high, state: state_open,
      body: "During peak hours (09:00-10:00 UTC), the connection pool hits the 50-connection limit and new requests queue for 30+ seconds. pgbouncer logs show long-running transactions from the reporting module holding connections." },
    { title: "Customer SSO redirects to wrong tenant",
      group: support, priority: prio_high, state: state_pending,
      body: "When customers from Acme Corp log in via OIDC, they are occasionally redirected to the wrong tenant dashboard. This appears to be a race condition in the session cookie when multiple tabs are open. Waiting on customer to provide HAR file." },
    { title: "Webhook delivery retries not respecting backoff",
      group: eng, priority: prio_normal, state: state_open,
      body: "Webhook delivery to external endpoints retries immediately on 503 responses instead of using exponential backoff. This causes thundering herd issues on the receiving service. The retry loop in worker/webhook.go ignores the Retry-After header." },
    { title: "Monthly billing report shows negative amounts",
      group: billing, priority: prio_normal, state: state_pending,
      body: "The February 2026 billing report for two customer orgs shows negative line items due to a credit memo that was applied twice. Accounting has flagged this. Pending review of the credit reconciliation logic." },
    { title: "Search index out of sync after bulk import",
      group: eng, priority: prio_low, state: state_open,
      body: "After importing 2,000 tickets via the bulk API, the Elasticsearch index is missing approximately 150 records. A manual reindex fixes the issue. Suspect the async indexing queue drops messages under high throughput." },
    { title: "Email notification templates contain broken links",
      group: support, priority: prio_low, state: state_closed,
      body: "Ticket notification emails contained links pointing to the old domain (support.example.com) instead of the new one (tickets.wisbric.com). Updated the NOTIFICATION_BASE_URL environment variable and redeployed." },
  ]

  tickets.each do |t|
    next if Ticket.find_by(title: t[:title])
    ticket = Ticket.create!(
      title:         t[:title],
      group:         t[:group],
      priority:      t[:priority] || prio_normal,
      state:         t[:state] || state_open,
      customer_id:   admin.id,
      updated_by_id: 1,
      created_by_id: 1,
    )
    Ticket::Article.create!(
      ticket_id:     ticket.id,
      type:          Ticket::Article::Type.find_by(name: "note"),
      sender:        Ticket::Article::Sender.find_by(name: "Agent"),
      from:          "admin@wisbric.local",
      subject:       t[:title],
      body:          t[:body],
      internal:      false,
      updated_by_id: 1,
      created_by_id: 1,
    )
    puts "Created ticket: #{t[:title]}"
  end

  puts "Done!"
'

echo ""
echo "=== Step 2: Update TicketOwl zammad_config in database ==="

kubectl exec -n "$NAMESPACE" "$PG_POD" -- env PGPASSWORD="$TICKETOWL_DB_PASS" psql -U ticketowl -d ticketowl -c "
  UPDATE tenant_acme.zammad_config
  SET url = 'http://owl-zammad:8080',
      api_token = '$TICKETOWL_TOKEN',
      updated_at = NOW()
"

echo ""
echo "=== Done! ==="
echo "Zammad admin:  admin@wisbric.local / OwlAdmin2026!"
echo "Zammad URL:    https://zammad.devops.lab"
echo "API token:     $TICKETOWL_TOKEN"
echo ""
echo "TicketOwl should now be able to connect to Zammad."
echo "Verify at: https://ticketowl.devops.lab/admin/zammad"
