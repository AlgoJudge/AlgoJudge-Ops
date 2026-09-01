#!/usr/bin/env bash
#
# Takes the installation out of service without stopping it, and waits until it
# is safe to touch the database.
#
#     ./scripts/maintenance.sh on "nightly backup"
#     ./scripts/maintenance.sh status
#     ./scripts/maintenance.sh off
#
# **This is a wrapper over `aj-admin maintenance`, not a mechanism of its own.**
# The Server owns maintenance: it enters `draining` immediately, lets work in
# flight finish, and closes when no evaluation is running or after
# `Maintenance:ForceAfterSeconds` — 300 by default. A submission that could not
# be evaluated because an operator started a backup goes back on the queue.
#
# **What this deliberately does not do is put a page in front of nginx.** An
# earlier design had a flag file that made the proxy answer 503 to everything.
# Three things break under that, and each on its own is enough:
#
#   * `/api/v1/health` must answer 200 at every maintenance level. The container's
#     own HEALTHCHECK greps it — a 503 has Docker kill the process the operator
#     is deliberately keeping alive — `docker compose up --wait` polls it, and it
#     is what a Client and a Runner poll to learn they may come back.
#   * The Client already has a maintenance page, in the installation's own
#     branding and language, driven by the Server's `server.maintenance` refusal.
#     A static page from the proxy replaces it with something worse.
#   * A proxy refusing everything refuses the Runner too, so nothing in flight
#     can finish and the drain never completes. The window would then always cost
#     an interrupted evaluation, which is the whole thing it exists to avoid.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

load_env

usage() {
    cat >&2 <<'TEXT'
Usage:
  maintenance.sh on [reason] [--wait-closed]
                             stop taking new work; finish what is claimed
  maintenance.sh off         serve again, immediately
  maintenance.sh status      what the switch is set to, and at what level

`on` returns as soon as the switch is thrown, which is `draining` — work already
claimed is still being finished and a Runner may still be writing a result.
`--wait-closed` waits for `closed`, which is what a backup or a restore needs
and what backup.sh --quiesce uses.
TEXT
    exit 2
}

have_server || die "no server container here. Maintenance is the Server's switch;
       a host that runs only Runners -- sandboxing or forwarding -- has nothing
       to throw."

# Waits for the drain to finish.
#
# **`closed` is the only level at which the database is safe to touch.** At
# `draining` a Runner may still be reporting a result, and a dump taken then is
# consistent but a restore of it loses that result with no trace. The Server
# reaches `closed` on its own once nothing is running, or after
# `Maintenance:ForceAfterSeconds`; the timeout here is a little past that default
# so a forced close is reported as a close rather than as our own timeout.
wait_closed() {
    local timeout=${1:-360} waited=0 level
    while [ "$waited" -lt "$timeout" ]; do
        level=$(aj_admin status | grep -o '"level":"[a-z]*"' | head -1 | cut -d'"' -f4)
        case "$level" in
            closed) log "closed after ${waited}s — nothing is running."; return 0 ;;
            open) die "the switch is off. Something turned it off while this was waiting." ;;
        esac
        sleep 5
        waited=$((waited + 5))
    done
    die "still draining after ${timeout}s. A Runner is wedged, or ForceAfterSeconds
       is set higher than this timeout. \`aj-admin status\` says the level."
}

case "${1-}" in
    on)
        shift
        reason=""
        wait=false
        for argument in "$@"; do
            case "$argument" in
                --wait-closed) wait=true ;;
                *) reason=$argument ;;
            esac
        done

        log "asking the Server to stop taking new work${reason:+ ($reason)}"
        aj_admin maintenance on "$reason"
        $wait && wait_closed
        ;;

    off)
        log "serving again"
        aj_admin maintenance off
        ;;

    status)
        aj_admin status
        ;;

    *) usage ;;
esac
