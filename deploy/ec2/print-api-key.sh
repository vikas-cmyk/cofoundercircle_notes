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

# Read the one key we need without sourcing: an unquoted value with spaces elsewhere in the
# file (DEFAULT_BOT_NAME) would word-split and run as a command.
if [ -f .env ]; then
  key="$(sed -n 's/^VEXA_API_KEY=//p' .env | tail -1)"
  case "$key" in
    \"*\") key="${key#\"}"; key="${key%\"}" ;;
    \'*\') key="${key#\'}"; key="${key%\'}" ;;
  esac
  if [ -n "$key" ]; then
    echo "VEXA_API_KEY=${key}"
    exit 0
  fi
fi

echo "No key yet. Wait ~30s after first boot, then re-run. Or set VEXA_API_KEY in .env." >&2
exit 1
