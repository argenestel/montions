#!/usr/bin/env bash
# Stops everything scripts/dev-up.sh started.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; STATE="$ROOT/.dev"
for f in anvil refresh keeper pricebot; do [ -f "$STATE/$f.pid" ] && kill "$(cat "$STATE/$f.pid")" 2>/dev/null; rm -f "$STATE/$f.pid"; done; echo stopped
