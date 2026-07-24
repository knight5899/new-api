#!/usr/bin/env bash

set -Eeuo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="$project_dir/.env"
image_name="new-api:baota"
public_url=""
port=""
bind_address=""
skip_build=false
dry_run=false

usage() {
  cat <<'EOF'
Usage: bash scripts/deploy-baota.sh [options]

Build the current repository and deploy it with Docker Compose for Baota.

Options:
  --public-url URL     Public HTTPS origin, for example https://api.example.com.
                       Enables secure session cookies and configures the trusted origin.
  --port PORT          Host port for New API. Defaults to 3000 on first deployment.
  --bind-address ADDR  Host bind address. Defaults to 127.0.0.1 on first deployment.
  --skip-build         Reuse the existing local image instead of building the repository.
  --dry-run            Generate configuration and validate Docker Compose without deploying.
  -h, --help           Show this help message.
EOF
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

read_env() {
  local key="$1"

  if [[ ! -f "$env_file" ]]; then
    return
  fi

  awk -v key="$key" '
    index($0, key "=") == 1 {
      sub(/^[^=]*=/, "")
      print
      exit
    }
  ' "$env_file"
}

upsert_env() {
  local key="$1"
  local value="$2"
  local temp_file

  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || fail "Invalid value for $key"
  temp_file="$(mktemp "${env_file}.tmp.XXXXXX")"

  if [[ -f "$env_file" ]]; then
    awk -v key="$key" -v value="$value" '
      BEGIN { replaced = 0 }
      index($0, key "=") == 1 {
        print key "=" value
        replaced = 1
        next
      }
      { print }
      END {
        if (!replaced) {
          print key "=" value
        }
      }
    ' "$env_file" > "$temp_file"
  else
    printf '%s=%s\n' "$key" "$value" > "$temp_file"
  fi

  chmod 600 "$temp_file"
  mv "$temp_file" "$env_file"
}

random_hex() {
  local bytes="$1"

  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$bytes"
    return
  fi

  od -An -N "$bytes" -tx1 /dev/urandom | tr -d ' \n'
}

ensure_secret() {
  local key="$1"
  local bytes="$2"
  local value

  value="$(read_env "$key")"
  case "$value" in
    '' | change-this-* | replace-with-*) upsert_env "$key" "$(random_hex "$bytes")" ;;
  esac
}

ensure_value() {
  local key="$1"
  local default_value="$2"

  [[ -n "$(read_env "$key")" ]] || upsert_env "$key" "$default_value"
}

wait_for_healthy() {
  local attempt health_state

  for attempt in {1..60}; do
    health_state="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' new-api 2>/dev/null || true)"
    if [[ "$health_state" == 'healthy' ]]; then
      return
    fi
    sleep 3
  done

  "${compose_cmd[@]}" ps >&2 || true
  "${compose_cmd[@]}" logs --tail=120 new-api >&2 || true
  fail 'New API did not become healthy within 180 seconds'
}

while (($# > 0)); do
  case "$1" in
    --public-url)
      (($# >= 2)) || fail '--public-url requires an HTTPS URL'
      public_url="$2"
      shift 2
      ;;
    --port)
      (($# >= 2)) || fail '--port requires a port number'
      port="$2"
      shift 2
      ;;
    --bind-address)
      (($# >= 2)) || fail '--bind-address requires an address'
      bind_address="$2"
      shift 2
      ;;
    --skip-build)
      skip_build=true
      shift
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
done

if [[ -n "$port" ]] && ! [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] || [[ -n "$port" && "$port" -gt 65535 ]]; then
  fail '--port must be between 1 and 65535'
fi

if [[ -n "$bind_address" && "$bind_address" == *$'\n'* ]]; then
  fail '--bind-address must be a single address'
fi

if [[ -n "$public_url" && ! "$public_url" =~ ^https://[^/[:space:]]+(:[0-9]{1,5})?$ ]]; then
  fail '--public-url must be an exact HTTPS origin, for example https://api.example.com'
fi

cd "$project_dir"

command -v docker >/dev/null 2>&1 || fail 'Docker is not installed. Install the Docker component in Baota first.'
docker info >/dev/null 2>&1 || fail 'Docker daemon is unavailable. Start Docker in Baota and run this script again.'

if docker compose version >/dev/null 2>&1; then
  compose_cmd=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  compose_cmd=(docker-compose)
else
  fail 'Docker Compose is not installed. Install the Docker Compose plugin in Baota first.'
fi

if [[ ! -f "$env_file" ]]; then
  cp docker-compose.env.example "$env_file"
  chmod 600 "$env_file"
fi

ensure_value NEW_API_BIND_ADDRESS 127.0.0.1
ensure_value NEW_API_PORT 3000
ensure_value POSTGRES_USER root
ensure_value POSTGRES_DB new-api
ensure_value TZ Asia/Shanghai
ensure_value ERROR_LOG_ENABLED true
ensure_value BATCH_UPDATE_ENABLED true
ensure_value NODE_NAME new-api-baota
ensure_secret POSTGRES_PASSWORD 24
ensure_secret REDIS_PASSWORD 24
ensure_secret SESSION_SECRET 32
ensure_secret CRYPTO_SECRET 32

if [[ -n "$port" ]]; then
  upsert_env NEW_API_PORT "$port"
fi

if [[ -n "$bind_address" ]]; then
  upsert_env NEW_API_BIND_ADDRESS "$bind_address"
fi

if [[ -n "$public_url" ]]; then
  upsert_env SESSION_COOKIE_SECURE true
  upsert_env SESSION_COOKIE_TRUSTED_URL "$public_url"
else
  ensure_value SESSION_COOKIE_SECURE false
fi

upsert_env NEW_API_IMAGE "$image_name"
mkdir -p data logs backups

"${compose_cmd[@]}" config --quiet

if [[ "$dry_run" == true ]]; then
  printf 'Configuration is valid. No image was built and no container was started.\n'
  exit 0
fi

if [[ "$skip_build" != true ]]; then
  docker build --tag "$image_name" .
fi

"${compose_cmd[@]}" up -d
wait_for_healthy

configured_port="$(read_env NEW_API_PORT)"
configured_bind_address="$(read_env NEW_API_BIND_ADDRESS)"
printf 'Deployment completed.\n'
if [[ -n "$public_url" ]]; then
  printf 'Public URL: %s\n' "$public_url"
elif [[ "$configured_bind_address" == '127.0.0.1' || "$configured_bind_address" == '::1' ]]; then
  printf 'New API listens on http://%s:%s for Baota reverse proxying.\n' "$configured_bind_address" "$configured_port"
  printf 'Configure an HTTPS reverse proxy in Baota, then rerun with --public-url https://your-domain.\n'
else
  printf 'New API listens on http://%s:%s.\n' "$configured_bind_address" "$configured_port"
fi
