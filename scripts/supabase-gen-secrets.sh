#!/usr/bin/env bash
#
# One-shot generator for the Supabase secret material (apps/supabase).
#
# Supabase needs a JWT secret PLUS two long-lived API keys (`anon`,
# `service_role`) that are JWTs SIGNED by that same secret — they must stay
# consistent or every client breaks. This script generates the secret, signs
# both keys, and prints a complete, ready-to-paste block of `.env` lines along
# with the other random tokens the stack needs.
#
# Usage:
#   ./scripts/supabase-gen-secrets.sh            # generate a fresh set
#   ./scripts/supabase-gen-secrets.sh >> .env    # append straight into .env
#
# Run it ONCE, keep the values (rotating SUPABASE_JWT_SECRET invalidates the
# anon/service keys; rotating SUPABASE_DB_PASSWORD breaks the existing DB).
# Then fill in SUPABASE_SMTP_PASSWORD (your Resend API key) and `make secrets`.
set -euo pipefail

# base64url (no padding) — the JWT wire format.
b64url() { openssl base64 -e -A | tr '+/' '-_' | tr -d '='; }

# Emit an HS256 JWT: gen_jwt <role> <secret>. Payload mirrors Supabase's
# self-host keys: {role, iss=supabase, iat=now, exp=now+10y}.
gen_jwt() {
  local role="$1" secret="$2" now exp header payload h p sig
  now="$(date +%s)"
  exp=$((now + 60 * 60 * 24 * 365 * 10))
  header='{"alg":"HS256","typ":"JWT"}'
  payload="$(printf '{"role":"%s","iss":"supabase","iat":%s,"exp":%s}' "$role" "$now" "$exp")"
  h="$(printf '%s' "$header" | b64url)"
  p="$(printf '%s' "$payload" | b64url)"
  sig="$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -hmac "$secret" -binary | b64url)"
  printf '%s.%s.%s' "$h" "$p" "$sig"
}

jwt_secret="$(openssl rand -hex 32)"
anon_key="$(gen_jwt anon "$jwt_secret")"
service_key="$(gen_jwt service_role "$jwt_secret")"

cat <<EOF
# --- supabase (apps/supabase) — generated $(date +%F) by scripts/supabase-gen-secrets.sh ---
# Stable secrets: generate ONCE and keep them. Rotating SUPABASE_JWT_SECRET
# invalidates the anon/service keys below; rotating SUPABASE_DB_PASSWORD breaks
# auth against the existing Postgres data. The DB password is hex on purpose so
# url-encoding it is a no-op (the chart reuses it verbatim in DATABASE_URLs).
SUPABASE_JWT_SECRET=$jwt_secret
SUPABASE_ANON_KEY=$anon_key
SUPABASE_SERVICE_KEY=$service_key
SUPABASE_DB_PASSWORD=$(openssl rand -hex 24)
SUPABASE_DASHBOARD_USERNAME=supabase
SUPABASE_DASHBOARD_PASSWORD=$(openssl rand -hex 16)
SUPABASE_ANALYTICS_PUBLIC_TOKEN=$(openssl rand -hex 32)
SUPABASE_ANALYTICS_PRIVATE_TOKEN=$(openssl rand -hex 32)
SUPABASE_REALTIME_SECRET_KEY_BASE=$(openssl rand -base64 64 | tr -d '\n')
SUPABASE_META_CRYPTO_KEY=$(openssl rand -hex 16)
SUPABASE_S3_KEY_ID=$(openssl rand -hex 16)
SUPABASE_S3_ACCESS_KEY=$(openssl rand -hex 32)
# Resend SMTP for auth emails: username is literally "resend", password is your
# Resend API key (re_...). The host/port/sender are non-secret (apps/supabase/values.yaml).
SUPABASE_SMTP_USERNAME=resend
SUPABASE_SMTP_PASSWORD=
# Optional: OpenAI key for Studio's SQL assistant (leave blank to disable).
SUPABASE_OPENAI_API_KEY=
EOF
