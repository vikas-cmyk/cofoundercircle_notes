#!/usr/bin/env bash
# Bring Vexa Lite up on a fresh Ubuntu 24.04 EC2 (amd64). Idempotent.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root: sudo $0" >&2
    exit 1
  fi
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    echo "Docker already installed"
    return
  fi
  echo "Installing Docker Engine..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
}

fill_secret() {
  local key="$1" file="$2"
  local cur
  cur="$(grep -E "^${key}=" "$file" | head -1 | cut -d= -f2- || true)"
  if [ -n "$cur" ]; then
    return
  fi
  local val
  val="$(openssl rand -hex 24)"
  if grep -qE "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$file"
  else
    printf '%s=%s\n' "$key" "$val" >>"$file"
  fi
  echo "minted $key"
}

need_root
install_docker

if [ ! -f .env ]; then
  cp .env.example .env
  echo "Wrote $DIR/.env from .env.example — fill VEXA_DOMAIN, ACME_EMAIL, TRANSCRIPTION_SERVICE_TOKEN, then re-run."
  exit 1
fi

fill_secret ADMIN_TOKEN .env
fill_secret INTERNAL_API_SECRET .env
fill_secret POSTGRES_PASSWORD .env
fill_secret MINIO_ACCESS_KEY .env
fill_secret MINIO_SECRET_KEY .env

# shellcheck disable=SC1091
set -a
# shellcheck source=/dev/null
. ./.env
set +a

if [ -z "${VEXA_DOMAIN:-}" ] || [ "$VEXA_DOMAIN" = "vexa.example.com" ]; then
  echo "Set VEXA_DOMAIN in $DIR/.env to the hostname whose A-record points at this box." >&2
  exit 1
fi
if [ -z "${ACME_EMAIL:-}" ] || [ "$ACME_EMAIL" = "ops@example.com" ]; then
  echo "Set ACME_EMAIL in $DIR/.env (Let's Encrypt)." >&2
  exit 1
fi
if [ -z "${TRANSCRIPTION_SERVICE_TOKEN:-}" ]; then
  echo "Set TRANSCRIPTION_SERVICE_TOKEN in $DIR/.env (Groq gsk_… or other STT token)." >&2
  exit 1
fi
if [ -z "${VEXA_PUBLIC_API_URL:-}" ]; then
  echo "VEXA_PUBLIC_API_URL is empty" >&2
  exit 1
fi

chmod +x print-api-key.sh 2>/dev/null || true

echo "Starting stack..."
docker compose up -d

echo "Waiting for gateway (up to 3 min)..."
ok=0
for _ in $(seq 1 36); do
  if curl -sf -o /dev/null http://127.0.0.1:8056/health 2>/dev/null; then
    ok=1
    break
  fi
  sleep 5
done
if [ "$ok" -ne 1 ]; then
  echo "Gateway did not become healthy. Logs:" >&2
  docker compose logs --tail=80 vexa >&2
  exit 1
fi

echo
echo "Vexa Lite is up."
echo "  API:     https://${VEXA_DOMAIN}"
echo "  Health:  https://${VEXA_DOMAIN}/health"
echo "  Docs:    https://${VEXA_DOMAIN}/docs"
echo
./print-api-key.sh || true
echo
echo "Point the Cofounder Circle backend at VEXA_API_URL=https://${VEXA_DOMAIN}"
echo "and POST /meetings with auto_join: true. Do not expose port 3001."
