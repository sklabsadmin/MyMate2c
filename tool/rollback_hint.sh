#!/usr/bin/env bash
#
# Shared by the two checks that run AFTER `wrangler deploy` — verify_deploy.sh
# and smoke_test.sh. Both can only fail once the build they are judging is
# already the one visitors are getting, so both need to answer the same urgent
# question: how do I stop serving this?
#
# On 7 Aug that question cost twenty minutes of reading deployment history
# while chat was down for everyone, because the failure output explained the
# cause and said nothing about the undo.
#
# Deliberately printed, never run. A rollback reverts code and bindings
# together — right when a deploy has just activated a rotated secret, wrong
# when the previous version is itself the broken one — and a script that
# silently un-deploys what someone just shipped is its own kind of outage.
#
# Usage: source this file, then call rollback_hint.

rollback_hint() {
    local worker previous
    # The deploy target, read from the same config wrangler deploys with, so a
    # worker rename cannot leave this pointing at the old name — which is the
    # mistake that put production on a two-week-old build in July.
    worker="$(sed -n 's/^[[:space:]]*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' wrangler.jsonc | head -1)"
    [[ -z "$worker" ]] && return 0

    echo >&2
    echo "       Production is serving this build right now. To put the previous" >&2
    echo "       version back while you work out why:" >&2
    echo >&2
    # Second-newest version id. Best-effort: if wrangler is unauthenticated or
    # its output shape changes, fall back to the bare command, which prompts
    # with the same choice interactively rather than failing here.
    previous="$(npx wrangler deployments list --name "$worker" 2>/dev/null \
                | sed -n 's/.*(100%) \([0-9a-f-]\{36\}\).*/\1/p' | tail -2 | head -1)"
    if [[ -n "$previous" ]]; then
        echo "         npx wrangler rollback $previous --name $worker" >&2
    else
        echo "         npx wrangler rollback --name $worker" >&2
    fi
    echo >&2
    echo "       Rolling back restores that version's code AND its secrets, so it" >&2
    echo "       also undoes a secret rotation this deploy activated." >&2
}
