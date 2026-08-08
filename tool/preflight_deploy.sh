#!/usr/bin/env bash
#
# Runs BEFORE `wrangler deploy`, and refuses rather than warns.
#
# Everything here is a failure that actually happened, not a hypothetical:
#
#   1. WRONG WORKER NAME. Cloudflare has no rename, so changing "name" in
#      wrangler.jsonc creates a NEW worker and leaves the old one serving. The
#      21 July mymate2c -> mymate-v2 rename did exactly that and production
#      served a two-week-old build until 5 August. Several branches still carry
#      a wrangler.jsonc naming a worker that has since been DELETED — deploying
#      one recreates it, pointed at nothing, and it takes the custom domains
#      with it (see 3). Checking out the wrong branch is all it takes.
#
#   2. DIRTY TREE. `npm run deploy` builds from the working tree, not from
#      HEAD. At 21:00 one evening another session's uncommitted work was
#      sitting in the tree; a deploy would have shipped unreviewed code to
#      production and left nothing in git saying what was live.
#
#   3. --name OVERRIDE. Same consequence as 1, but invisible in the config —
#      it lives in whatever command someone typed.
#
# Deliberately refuses on things a human could reasonably wave through. A
# deploy here is a live revenue path and the failures above were all silent:
# each one reported success and served the wrong thing.
#
# Usage: bash tool/preflight_deploy.sh
#        EXPECTED_WORKER=other-name bash tool/preflight_deploy.sh   # rare
#        ALLOW_DIRTY=1 bash tool/preflight_deploy.sh                # emergency
set -euo pipefail

cd "$(dirname "$0")/.."

EXPECTED_WORKER="${EXPECTED_WORKER:-mythoslive}"
fail() { echo "PREFLIGHT FAILED: $*" >&2; exit 1; }

# ---------------------------------------------------------------- worker name
#
# Read from the same file wrangler deploys with, using the same crude parse as
# rollback_hint.sh, so the two cannot disagree about what is being deployed.
name="$(sed -n 's/^[[:space:]]*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' wrangler.jsonc | head -1)"

if [[ -z "$name" ]]; then
  fail "no \"name\" found in wrangler.jsonc — refusing to deploy a config I cannot read."
fi

if [[ "$name" != "$EXPECTED_WORKER" ]]; then
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
  fail "wrangler.jsonc names worker '$name', expected '$EXPECTED_WORKER'.
       You are on branch '$branch'. Several old branches still name workers
       that have been deleted; deploying one recreates it and takes the
       custom domains with it. Check out main, or set EXPECTED_WORKER if
       this really is a new target."
fi

# ------------------------------------------------------------ --name override
#
# A --name flag beats the config entirely, so the check above proves nothing on
# its own. npm appends `--` args to the LAST command in a chained script rather
# than to wrangler, so the realistic way this arrives is someone editing the
# deploy script — which is what is inspected here.
deploy_script="$(node -e 'process.stdout.write(require("./package.json").scripts.deploy || "")' 2>/dev/null || true)"
if [[ "$deploy_script" == *"--name"* ]]; then
  fail "package.json's deploy script contains a --name override:
         $deploy_script
       That silently beats wrangler.jsonc. Remove it."
fi

# ------------------------------------------------------------------ git state
#
# Tracked, modified files only. build/ is gitignored and is *expected* to
# differ — it is a build artefact — so it is the source that has to be clean.
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  fail "not a git repository — cannot tell what is about to be deployed."
fi

dirty="$(git status --porcelain --untracked-files=no)"
if [[ -n "$dirty" ]] && [[ "${ALLOW_DIRTY:-}" != "1" ]]; then
  fail "working tree has uncommitted changes:
$(echo "$dirty" | sed 's/^/         /')
       npm run deploy builds from the tree, not from HEAD, so these would go
       live with nothing in git recording it. Commit or stash first.
       ALLOW_DIRTY=1 overrides, for an emergency you are watching."
fi

# Not fatal: deploying an unpushed commit is recoverable, it is just invisible
# to anyone else — including whoever has to work out what is live at 3am.
if git rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
  if [[ -n "$(git log '@{upstream}..HEAD' --oneline)" ]]; then
    echo "==> WARNING: HEAD is ahead of its upstream; what you deploy is not pushed yet." >&2
  fi
else
  echo "==> WARNING: branch has no upstream; what you deploy exists only on this machine." >&2
fi

echo "==> preflight ok: worker '$name', tree clean, HEAD $(git rev-parse --short HEAD)"
