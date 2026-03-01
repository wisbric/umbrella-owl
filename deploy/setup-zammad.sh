#!/usr/bin/env bash
# =============================================================================
# setup-zammad.sh — One-time Zammad provisioning for running lab environment
# =============================================================================
# Creates admin user, service user, API token, sample data in Zammad,
# then updates TicketOwl's zammad_config in the database.
#
# NOTE: Zammad auto-generates API token values — you cannot set a custom token.
# This script reads back the generated token and writes it to TicketOwl's DB.
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

# TicketOwl DB password (from values.lab-secrets.yaml)
TICKETOWL_DB_PASS="${TICKETOWL_DB_PASS:-M7ov36EIDVFFFE5xDqZSXZH7Wn0cH8O5}"

# Helper: run a rails runner script via stdin to avoid URI-too-large errors.
run_rails() {
  kubectl exec -i -n "$NAMESPACE" "$ZAMMAD_POD" -c "$ZAMMAD_CONTAINER" -- rails runner -
}

# Helper: run rails and extract a value between markers (ignores Rails log noise).
run_rails_extract() {
  local marker="$1"
  shift
  run_rails "$@" | grep -oP "${marker}\\K[^[:space:]]+"
}

echo "=== Step 1: Create admin + service user + API token ==="

run_rails <<'RUBY'
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

  token_name = "TicketOwl Integration"
  t = Token.find_by(user_id: svc.id, name: token_name)
  unless t
    t = Token.create!(
      user_id:    svc.id,
      name:       token_name,
      action:     "api",
      persistent: true,
    )
    puts "Created API token: #{token_name}"
  else
    puts "API token already exists: #{token_name}"
  end

  # Output the Zammad-generated token value for the next step.
  puts "ZAMMAD_TOKEN=#{t.token}"
RUBY

echo ""
echo "=== Step 2: Read back the generated API token ==="

TICKETOWL_TOKEN=$(run_rails_extract "ZAMMAD_TOKEN=" <<'RUBY'
  svc = User.find_by(login: "ticketowl-service")
  t = Token.find_by(user_id: svc.id, name: "TicketOwl Integration")
  puts "ZAMMAD_TOKEN=#{t.token}"
RUBY
)

if [[ -z "$TICKETOWL_TOKEN" ]]; then
  echo "ERROR: Could not read API token from Zammad."
  exit 1
fi
echo "API token: ${TICKETOWL_TOKEN:0:12}..."

echo ""
echo "=== Step 3: Create groups and organizations ==="

run_rails <<'RUBY'
  %w[Support Engineering Billing].each do |name|
    unless Group.find_by(name: name)
      Group.create!(name: name, active: true, updated_by_id: 1, created_by_id: 1)
      puts "Created group: #{name}"
    else
      puts "Group already exists: #{name}"
    end
  end

  ["Acme Corp", "Wisbric"].each do |name|
    unless Organization.find_by(name: name)
      Organization.create!(name: name, active: true, updated_by_id: 1, created_by_id: 1)
      puts "Created organization: #{name}"
    else
      puts "Organization already exists: #{name}"
    end
  end

  puts "Step 3 done."
RUBY

echo ""
echo "=== Step 4: Create sample tickets (batch 1/2) ==="

run_rails <<'RUBY'
  admin   = User.find_by(login: "admin@wisbric.local")
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
      body: "After the v2.4.1 upgrade the login endpoint returns a 500 error for all users." },
    { title: "API rate limiting not working",
      group: eng, priority: prio_normal, state: state_open,
      body: "Rate limiting middleware is configured for 100 req/min but load testing shows no throttling at 500 req/min." },
    { title: "Invoice PDF generation broken",
      group: billing, priority: prio_high, state: state_open,
      body: "PDF generation for invoices fails with a wkhtmltopdf timeout. Affects all invoices created after 2026-02-15." },
    { title: "Dashboard widget not loading for IE users",
      group: support, priority: prio_low, state: state_closed,
      body: "Legacy IE11 users report the analytics dashboard widget shows a blank white box. Fixed by adding Babel plugin." },
    { title: "Database connection pool exhausted under load",
      group: eng, priority: prio_high, state: state_open,
      body: "During peak hours the connection pool hits the 50-connection limit. pgbouncer logs show long-running transactions." },
  ]

  tickets.each do |t|
    next if Ticket.find_by(title: t[:title])
    ticket = Ticket.create!(
      title: t[:title], group: t[:group], priority: t[:priority],
      state: t[:state], customer_id: admin.id, updated_by_id: 1, created_by_id: 1,
    )
    Ticket::Article.create!(
      ticket_id: ticket.id, type: Ticket::Article::Type.find_by(name: "note"),
      sender: Ticket::Article::Sender.find_by(name: "Agent"), from: "admin@wisbric.local",
      subject: t[:title], body: t[:body], internal: false, updated_by_id: 1, created_by_id: 1,
    )
    puts "Created ticket: #{t[:title]}"
  end
  puts "Batch 1 done."
RUBY

echo ""
echo "=== Step 5: Create sample tickets (batch 2/2) ==="

run_rails <<'RUBY'
  admin   = User.find_by(login: "admin@wisbric.local")
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
    { title: "Customer SSO redirects to wrong tenant",
      group: support, priority: prio_high, state: state_pending,
      body: "Acme Corp users occasionally redirected to wrong tenant dashboard via OIDC. Waiting on HAR file." },
    { title: "Webhook delivery retries not respecting backoff",
      group: eng, priority: prio_normal, state: state_open,
      body: "Webhook delivery retries immediately on 503 instead of using exponential backoff." },
    { title: "Monthly billing report shows negative amounts",
      group: billing, priority: prio_normal, state: state_pending,
      body: "February 2026 billing report shows negative line items due to a credit memo applied twice." },
    { title: "Search index out of sync after bulk import",
      group: eng, priority: prio_low, state: state_open,
      body: "After importing 2000 tickets the Elasticsearch index is missing about 150 records." },
    { title: "Email notification templates contain broken links",
      group: support, priority: prio_low, state: state_closed,
      body: "Notification emails contained links to the old domain. Updated NOTIFICATION_BASE_URL and redeployed." },
  ]

  tickets.each do |t|
    next if Ticket.find_by(title: t[:title])
    ticket = Ticket.create!(
      title: t[:title], group: t[:group], priority: t[:priority],
      state: t[:state], customer_id: admin.id, updated_by_id: 1, created_by_id: 1,
    )
    Ticket::Article.create!(
      ticket_id: ticket.id, type: Ticket::Article::Type.find_by(name: "note"),
      sender: Ticket::Article::Sender.find_by(name: "Agent"), from: "admin@wisbric.local",
      subject: t[:title], body: t[:body], internal: false, updated_by_id: 1, created_by_id: 1,
    )
    puts "Created ticket: #{t[:title]}"
  end
  puts "Batch 2 done."
RUBY

echo ""
echo "=== Step 6: Update TicketOwl zammad_config in database ==="

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
echo "API token:     ${TICKETOWL_TOKEN:0:12}..."
echo ""
echo "TicketOwl should now be able to connect to Zammad."
echo "Verify at: https://ticketowl.devops.lab/admin/zammad"
