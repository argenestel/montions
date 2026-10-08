#!/usr/bin/env bash
# Publishes the built frontend to the `gh-pages` BRANCH (no GitHub Actions / workflow permission needed).
# Then in GitHub: Settings -> Pages -> Source: "Deploy from a branch" -> gh-pages / (root). URL: https://<user>.github.io/<repo>/
# Requires app/public/deployment.json to be the REAL deployment manifest (testnet or mainnet), not a fork/local one.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
REPO="${REPO_NAME:-montions}"; M=app/public/deployment.json
[ -f "$M" ] || { echo "missing $M — deploy first"; exit 1; }
NET="$(jq -r .network "$M")"; RPC="$(jq -r .rpc "$M")"
case "$NET" in testnet|mainnet) ;; *) echo "REFUSING: manifest network is '$NET' (a local/fork manifest would publish dead addresses)"; exit 1;; esac
case "$RPC" in http://127.*|http://localhost*) echo "REFUSING: manifest RPC is localhost"; exit 1;; esac
( cd app && pnpm install --frozen-lockfile >/dev/null && pnpm exec vite build --base "/$REPO/" )
cp app/dist/index.html app/dist/404.html          # SPA fallback for GitHub Pages
touch app/dist/.nojekyll
TMP="$(mktemp -d)"; git worktree add -f "$TMP" -B gh-pages >/dev/null 2>&1 || git worktree add -f "$TMP" gh-pages
git -C "$TMP" rm -rf . >/dev/null 2>&1 || true; cp -r app/dist/. "$TMP"/; touch "$TMP/.nojekyll"
git -C "$TMP" add -A && git -C "$TMP" -c user.name="$(git config user.name)" -c user.email="$(git config user.email)" commit -q -m "publish $(date -u +%FT%TZ) ($NET)" && git -C "$TMP" push -f origin gh-pages
git worktree remove --force "$TMP"
echo "✔ published to branch gh-pages. Enable Pages (Settings -> Pages -> gh-pages / root) and open https://$(git config user.name).github.io/$REPO/"
