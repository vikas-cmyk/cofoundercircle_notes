#!/usr/bin/env bash
# Print the Lite-minted API key (or the operator-supplied VEXA_API_KEY).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

if docker compose exec -T vexa test -f /run/vexa/key.env 2>/dev/null; then
  echo "=== minted keys (from Lite) ==="
  docker compose exec -T vexa cat /run/vexa/key.env
  exit 0
fi

# shellcheck disable=SC1091
set -a
[ -f .env ] && . ./.env
set +a
if [ -n "${VEXA_API_KEY:-}" ]; then
  echo "VEXA_API_KEY=${VEXA_API_KEY}"
  exit 0
fi

echo "No key yet. Wait ~30s after first boot, then re-run. Or set VEXA_API_KEY in .env." >&2
exit 1
