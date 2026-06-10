#!/usr/bin/env bash
#
# Recreate (or rotate) the cluster's Secrets from values in secrets.enc.env —
# a sops-encrypted dotenv that IS committed to git (age-encrypted; .sops.yaml
# holds the recipient). Decryption happens in-memory below: plaintext secrets
# never touch disk or git.
#
# One block per app below — each owns its namespace's Secrets and validates only
# its own variables, so bootstrapping the platform never depends on app secrets.
# Uninstalling an app = delete its block here (+ its secrets.enc.env vars).
#
# Usage:
#   make secrets-edit                         # sops opens your editor: fill values
#   ./scripts/apply-secrets.sh                # all blocks; one is skipped (with a
#                                             #   note) if its key var is unset
#   ./scripts/apply-secrets.sh cert-manager   # just one block — hard-fails if its
#   ./scripts/apply-secrets.sh multica ...    #   vars are missing (any of:
#                                             #   cert-manager wallos multica supabase)
#
# Idempotent: uses `create --dry-run=client | apply` so it creates or updates.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

secrets_file="secrets.enc.env"

command -v sops >/dev/null 2>&1 \
  || { echo "ERROR: sops not found in PATH (brew install sops age)." >&2; exit 1; }
if [[ ! -f "$secrets_file" ]]; then
  echo "ERROR: $secrets_file not found. Bootstrap: make secrets-edit (see README — Secrets policy)." >&2
  exit 1
fi

# Capture first so a failed decrypt (missing/wrong age key) aborts loudly,
# instead of silently sourcing nothing and "skipping" every block.
env_clear="$(sops -d "$secrets_file")" || {
  echo "ERROR: could not decrypt $secrets_file — is the age private key in place?" >&2
  echo "       (macOS: '~/Library/Application Support/sops/age/keys.txt'; Linux: ~/.config/sops/age/keys.txt)" >&2
  exit 1
}
# eval, not `source <(...)`: plaintext stays in-memory and it works on the
# bash 3.2 that macOS ships (where sourcing a process substitution is a no-op).
set -a
eval "$env_clear"
set +a
unset env_clear

ensure_ns() {
  kubectl create namespace "$1" --dry-run=client -o yaml | kubectl apply -f -
}

# backup-r2 (one per app namespace): S3 credentials for that app's nightly backup
# CronJob (apps/<app>/backup.yaml -> Cloudflare R2). Key names double as rclone env
# config (RCLONE_CONFIG_R2_* -> a config-less "r2" remote via envFrom); the
# non-secret TYPE/PROVIDER env lives in the CronJob manifests.
backup_r2_secret() {
  local ns="$1"
  if [[ -z "${BACKUP_R2_ACCESS_KEY_ID:-}" ]]; then
    echo "    (backup-r2 skipped: BACKUP_R2_* not set in secrets.enc.env)"
    return 0
  fi
  : "${BACKUP_R2_SECRET_ACCESS_KEY:?set BACKUP_R2_SECRET_ACCESS_KEY in secrets.enc.env}"
  : "${BACKUP_R2_BUCKET:?set BACKUP_R2_BUCKET in secrets.enc.env}"
  : "${BACKUP_R2_ENDPOINT_URL:?set BACKUP_R2_ENDPOINT_URL in secrets.enc.env}"
  kubectl create secret generic backup-r2 \
    --namespace "$ns" \
    --from-literal=RCLONE_CONFIG_R2_ACCESS_KEY_ID="$BACKUP_R2_ACCESS_KEY_ID" \
    --from-literal=RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$BACKUP_R2_SECRET_ACCESS_KEY" \
    --from-literal=RCLONE_CONFIG_R2_ENDPOINT="$BACKUP_R2_ENDPOINT_URL" \
    --from-literal=BACKUP_BUCKET="$BACKUP_R2_BUCKET" \
    --dry-run=client -o yaml | kubectl apply -f -
}

# --- cert-manager (platform) -------------------------------------------------
cert_manager_secrets() {
  : "${CLOUDFLARE_API_TOKEN:?set CLOUDFLARE_API_TOKEN in secrets.enc.env}"
  echo "==> cert-manager / cloudflare-api-token"
  ensure_ns cert-manager
  kubectl create secret generic cloudflare-api-token \
    --namespace cert-manager \
    --from-literal=api-token="$CLOUDFLARE_API_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -
}

# --- wallos (apps/wallos) ----------------------------------------------------
# Wallos itself needs no secrets; the only one in its namespace is backup-r2.
wallos_secrets() {
  echo "==> wallos / backup-r2"
  ensure_ns wallos
  backup_r2_secret wallos
}

# --- multica (apps/multica) --------------------------------------------------
# multica's backend reads this Secret via envFrom and Postgres pulls POSTGRES_PASSWORD
# by name, so it only needs the keys actually in use — missing optional keys are simply
# not injected (no need to carry empty placeholders). The chart has no extra-env knob,
# so the non-secret GitHub SLUG/APP_ID ride here too (envFrom is the only hook). To turn
# on Google OAuth / CloudFront later, add GOOGLE_CLIENT_SECRET / CLOUDFRONT_PRIVATE_KEY here.
multica_secrets() {
  : "${MULTICA_JWT_SECRET:?set MULTICA_JWT_SECRET in secrets.enc.env (openssl rand -hex 32)}"
  : "${MULTICA_POSTGRES_PASSWORD:?set MULTICA_POSTGRES_PASSWORD in secrets.enc.env (openssl rand -hex 16)}"
  echo "==> multica / multica-secrets"
  ensure_ns multica
  # The GitHub App private key is a multiline PEM kept base64 on one secrets.enc.env line; decode it
  # to a temp file so --from-file stores the exact PEM bytes (newlines intact).
  # Deliberately not `local`: the EXIT trap fires after the function returns.
  ghkey_tmp="$(mktemp)"
  trap 'rm -f "${ghkey_tmp:-}"' EXIT
  printf '%s' "${MULTICA_GITHUB_APP_PRIVATE_KEY_B64:-}" | openssl base64 -d -A > "$ghkey_tmp" 2>/dev/null || true
  kubectl create secret generic multica-secrets \
    --namespace multica \
    --from-literal=JWT_SECRET="$MULTICA_JWT_SECRET" \
    --from-literal=POSTGRES_PASSWORD="$MULTICA_POSTGRES_PASSWORD" \
    --from-literal=RESEND_API_KEY="${MULTICA_RESEND_API_KEY:-}" \
    --from-literal=GITHUB_APP_SLUG="${MULTICA_GITHUB_APP_SLUG:-}" \
    --from-literal=GITHUB_APP_ID="${MULTICA_GITHUB_APP_ID:-}" \
    --from-literal=GITHUB_WEBHOOK_SECRET="${MULTICA_GITHUB_WEBHOOK_SECRET:-}" \
    --from-file=GITHUB_APP_PRIVATE_KEY="$ghkey_tmp" \
    --dry-run=client -o yaml | kubectl apply -f -
  backup_r2_secret multica
}

# --- supabase (apps/supabase) ------------------------------------------------
# The Supabase chart references one Secret per concern (secret.<group>.secretRef in
# apps/supabase/values.yaml), each using the chart's natural key names so no key
# remapping is needed. We create them out-of-band here so no secret is templated into
# git. The `apikey` secret is intentionally NOT created: leaving it empty keeps the
# classic symmetric-JWT (anon/service-key) auth model; the chart's kong-entrypoint
# strips the empty key-auth credentials at boot.
supabase_secrets() {
  : "${SUPABASE_JWT_SECRET:?set the SUPABASE_* block in secrets.enc.env (run ./scripts/supabase-gen-secrets.sh)}"
  : "${SUPABASE_ANON_KEY:?missing SUPABASE_ANON_KEY (re-run ./scripts/supabase-gen-secrets.sh)}"
  : "${SUPABASE_SERVICE_KEY:?missing SUPABASE_SERVICE_KEY (re-run ./scripts/supabase-gen-secrets.sh)}"
  : "${SUPABASE_DB_PASSWORD:?missing SUPABASE_DB_PASSWORD (re-run ./scripts/supabase-gen-secrets.sh)}"
  echo "==> supabase / supabase-* secrets"
  ensure_ns supabase
  kubectl create secret generic supabase-jwt \
    --namespace supabase \
    --from-literal=anonKey="$SUPABASE_ANON_KEY" \
    --from-literal=serviceKey="$SUPABASE_SERVICE_KEY" \
    --from-literal=secret="$SUPABASE_JWT_SECRET" \
    --dry-run=client -o yaml | kubectl apply -f -
  # Hex password => url-encoding is a no-op, so the chart safely reuses `password` as the
  # url-encoded password it embeds in DATABASE_URLs (no separate password_encoded key).
  kubectl create secret generic supabase-db \
    --namespace supabase \
    --from-literal=password="$SUPABASE_DB_PASSWORD" \
    --from-literal=database="postgres" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret generic supabase-dashboard \
    --namespace supabase \
    --from-literal=username="${SUPABASE_DASHBOARD_USERNAME:-supabase}" \
    --from-literal=password="$SUPABASE_DASHBOARD_PASSWORD" \
    --from-literal=openAiApiKey="${SUPABASE_OPENAI_API_KEY:-}" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret generic supabase-analytics \
    --namespace supabase \
    --from-literal=publicAccessToken="$SUPABASE_ANALYTICS_PUBLIC_TOKEN" \
    --from-literal=privateAccessToken="$SUPABASE_ANALYTICS_PRIVATE_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret generic supabase-realtime \
    --namespace supabase \
    --from-literal=secretKeyBase="$SUPABASE_REALTIME_SECRET_KEY_BASE" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret generic supabase-meta \
    --namespace supabase \
    --from-literal=cryptoKey="$SUPABASE_META_CRYPTO_KEY" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret generic supabase-s3 \
    --namespace supabase \
    --from-literal=keyId="$SUPABASE_S3_KEY_ID" \
    --from-literal=accessKey="$SUPABASE_S3_ACCESS_KEY" \
    --dry-run=client -o yaml | kubectl apply -f -
  # username "resend", password = Resend API key; auth wires these to GOTRUE_SMTP_USER/PASS.
  kubectl create secret generic supabase-smtp \
    --namespace supabase \
    --from-literal=username="${SUPABASE_SMTP_USERNAME:-resend}" \
    --from-literal=password="${SUPABASE_SMTP_PASSWORD:-}" \
    --dry-run=client -o yaml | kubectl apply -f -
  backup_r2_secret supabase
}

# --- selection ----------------------------------------------------------------
if [[ $# -gt 0 ]]; then
  for app in "$@"; do
    case "$app" in
      cert-manager) cert_manager_secrets ;;
      wallos)       wallos_secrets ;;
      multica)      multica_secrets ;;
      supabase)     supabase_secrets ;;
      *)
        echo "ERROR: unknown app '$app' (valid: cert-manager wallos multica supabase)" >&2
        exit 1
        ;;
    esac
  done
else
  # No args: apply every block whose key variable is set in secrets.enc.env, skip the rest.
  if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then cert_manager_secrets; else echo "==> cert-manager: skipped (CLOUDFLARE_API_TOKEN not set)"; fi
  if [[ -n "${BACKUP_R2_ACCESS_KEY_ID:-}" ]]; then wallos_secrets; else echo "==> wallos: skipped (BACKUP_R2_* not set)"; fi
  if [[ -n "${MULTICA_JWT_SECRET:-}" ]]; then multica_secrets; else echo "==> multica: skipped (MULTICA_JWT_SECRET not set)"; fi
  if [[ -n "${SUPABASE_JWT_SECRET:-}" ]]; then supabase_secrets; else echo "==> supabase: skipped (SUPABASE_JWT_SECRET not set)"; fi
fi

echo "Done. Secrets are in-cluster; nothing was written to git."
