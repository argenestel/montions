#!/usr/bin/env bash
# Asserts the local book has the canonical ladder: exactly N planned series, no
# duplicate (resolver, data, expiry) keys, and vault quotes on >= 20 series.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
if [[ -z "${RPC_URL:-}" ]]; then
  if [[ -z "${ANVIL_PORT:-}" ]]; then
    echo "dev-check: set RPC_URL or ANVIL_PORT" >&2
    exit 1
  fi
  export RPC_URL="http://127.0.0.1:${ANVIL_PORT}"
fi
export DEPLOYMENT="${DEPLOYMENT:-$ROOT/deployments/31337.json}"
if [[ ! -f "$DEPLOYMENT" ]]; then
  echo "dev-check: missing $DEPLOYMENT" >&2
  exit 1
fi
pnpm --dir bots exec tsx src/dev-check.ts
