#!/usr/bin/env bash
#
# Run the whole app locally — worker, static assets and D1 — with no Cloudflare
# account and no production secrets.
#
# This exists so an agent (or anyone without .env) can actually see a change
# working instead of only running `flutter test`. `wrangler dev --local` serves
# backend/src/worker.js and build/web together on one origin, exactly as the
# deployed worker does, using Miniflare's local D1 rather than the real one.
#
# The signature check is the reason this needs any secret at all: the worker
# rejects /api/chat unless the client's HMAC matches env.APP_SECRET. Locally we
# control both sides, so they only have to match EACH OTHER — a throwaway dev
# value works, and no production secret ever has to enter the sandbox.
#
# What does NOT work here, by design:
#   - Chat replies. The worker calls OpenAI/Inworld with API keys we do not
#     have, so /api/chat authenticates fine and then fails at the upstream call.
#   - Google Sign-In. Needs GOOGLE_CLIENT_SECRET and a registered redirect URI.
#   - Anything reading production data. Local D1 starts empty.
#
# Usage:
#   npm run preview          # build, serve on :8788, stay up (Ctrl-C to stop)
#   npm run preview:shot     # build, serve, screenshot, exit
#   SKIP_BUILD=1 npm run preview:shot    # reuse the existing build/web
set -euo pipefail

cd "$(dirname "$0")/.."

MODE="${1:-serve}"
PORT="${PREVIEW_PORT:-8788}"
OUT_DIR="${SHOT_DIR:-build/preview-shots}"

# Dev-only, and deliberately not a secret. Both the client build and the worker
# get this same value, which is all the HMAC check requires. Override with
# PREVIEW_SECRET if you want to point a local client at a real backend.
PREVIEW_SECRET="${PREVIEW_SECRET:-local-preview-secret-not-for-deploy}"

# .dev.vars is how wrangler feeds secrets to a local worker (it is gitignored,
# same as .env). Only create it when absent so a hand-written one is preserved.
if [[ ! -f .dev.vars ]]; then
  echo "==> writing .dev.vars (gitignored) with the dev secret"
  printf 'APP_SECRET=%s\n' "$PREVIEW_SECRET" > .dev.vars
elif ! grep -q '^APP_SECRET=' .dev.vars; then
  echo "==> appending APP_SECRET to existing .dev.vars"
  printf 'APP_SECRET=%s\n' "$PREVIEW_SECRET" >> .dev.vars
else
  # Respect the existing value and build the client against it, or every
  # signed request fails with the confusing "Invalid signature".
  PREVIEW_SECRET="$(grep '^APP_SECRET=' .dev.vars | head -1 | cut -d= -f2-)"
  echo "==> using APP_SECRET already present in .dev.vars"
fi

if [[ -z "${SKIP_BUILD:-}" ]]; then
  # Same origin for app and API, so WORKER_URL points back at this server.
  APP_SECRET="$PREVIEW_SECRET" \
  WORKER_URL="http://127.0.0.1:${PORT}" \
    bash tool/build_web.sh
else
  echo "==> SKIP_BUILD set, reusing existing build/web"
fi

echo "==> starting wrangler dev --local on :${PORT}"
npx wrangler dev --local --port "$PORT" > /tmp/preview-wrangler.log 2>&1 &
WRANGLER_PID=$!
cleanup() { kill "$WRANGLER_PID" 2>/dev/null || true; }
trap cleanup EXIT

# -s not -sS: the first few attempts legitimately fail while wrangler boots, and
# printing those connection errors makes a healthy start look broken.
if ! curl -s --retry 30 --retry-delay 2 --retry-connrefused --max-time 120 \
     -o /dev/null "http://127.0.0.1:${PORT}/"; then
  echo "ERROR: worker never came up on :${PORT}. Log:" >&2
  tail -20 /tmp/preview-wrangler.log >&2
  exit 1
fi
echo "==> ready: http://127.0.0.1:${PORT}"

if [[ "$MODE" == "shot" ]]; then
  mkdir -p "$OUT_DIR"
  # Playwright is not a project dependency — it ships preinstalled in the agent
  # container. Fall back to the global install rather than adding a ~300MB dep
  # that only the screenshot path needs.
  if ! node -e "require.resolve('playwright')" 2>/dev/null; then
    export NODE_PATH="${NODE_PATH:+$NODE_PATH:}/opt/node22/lib/node_modules"
    if ! node -e "require.resolve('playwright')" 2>/dev/null; then
      echo "ERROR: playwright not found. Install it (npm i -D playwright) or run" >&2
      echo "       'npm run preview' and look at :${PORT} in a browser instead." >&2
      exit 1
    fi
  fi
  SHOT_URL="http://127.0.0.1:${PORT}/" SHOT_OUT="$OUT_DIR" node tool/screenshot_web.js
  echo "==> screenshots in ${OUT_DIR}/"
else
  echo "    Ctrl-C to stop. Worker log: /tmp/preview-wrangler.log"
  wait "$WRANGLER_PID"
fi
