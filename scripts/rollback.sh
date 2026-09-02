#!/usr/bin/env bash
#
# Puts back the images that were running before the last successful update.
#
#     ./scripts/rollback.sh
#     ./scripts/rollback.sh --yes
#
# **Digests, not tags.** `state/current.lock` holds what was actually running, so
# this restores that image whatever `SERVER_TAG` points at today — which is the
# whole reason the lock file exists. A moving tag that has since moved again
# would otherwise roll forward.
#
# **A rollback is not a time machine, and this script says so.** If the update
# applied a migration, putting the old image back leaves a database whose schema
# is ahead of it — and an older Server meeting a newer schema does not start.
# `state/last-migration` records that, and this refuses to pretend otherwise.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

load_env

confirm=true
from_update=false
for argument in "$@"; do
    case "$argument" in
        --yes) confirm=false ;;
        # Called by update.sh, which already holds the lock and has already
        # closed the installation.
        --from-update) from_update=true; confirm=false ;;
        *) die "unknown argument: $argument" ;;
    esac
done

$from_update || lock

LOCK_FILE="$ROOT/state/current.lock"
[ -s "$LOCK_FILE" ] || die "no state/current.lock, so there is no recorded set of images
       to go back to. It is written by a successful update; an installation that
       has never updated has nothing to roll back to."

log "rolling back to:"
sed 's/^/       /' "$LOCK_FILE"

# ── The schema, which a rollback cannot undo ────────────────────────────────

if [ -f "$ROOT/state/last-migration" ]; then
    from=$(grep -m1 '^from=' "$ROOT/state/last-migration" | cut -d= -f2-)
    to=$(grep -m1 '^to=' "$ROOT/state/last-migration" | cut -d= -f2-)
    dump=$(grep -m1 '^dump_before=' "$ROOT/state/last-migration" | cut -d= -f2-)

    warn "the last update applied a migration, and putting the old image back does
       not undo it.
         was:     $from
         now:     $to
       An older Server against a newer schema refuses to start. If that happens,
       restore the database from the dump taken immediately before:
         ./scripts/restore.sh $dump
       That is the only way back, and it loses everything written since."

    if $confirm; then
        printf 'Roll back anyway? Type the word rollback: '
        read -r answer
        [ "$answer" = "rollback" ] || die "not confirmed; nothing was touched."
        confirm=false
    fi
fi

if $confirm; then
    printf 'Replace the running images with the ones above? [y/N] '
    read -r answer
    case "$answer" in [yY]*) : ;; *) die "not confirmed; nothing was touched." ;; esac
fi

# ── Doing it ────────────────────────────────────────────────────────────────
#
# **Each service is pinned to its digest through an override**, rather than by
# editing `.env`. Writing a digest into `.env` would leave the installation
# pinned after somebody had forgotten why, and the next `update.sh` would find
# "nothing new" for ever.

override="$ROOT/state/rollback.compose.yaml"
{
    printf 'services:\n'
    while read -r service image; do
        [ -n "$service" ] || continue
        printf '  %s:\n    image: %s\n' "$service" "$image"
    done <"$LOCK_FILE"
} >"$override"

$from_update || "$ROOT/scripts/maintenance.sh" on "rollback" --wait-closed || true

# **Appended to `COMPOSE_FILE`, not passed with `-f`.** An explicit `-f` replaces
# the whole list, so an installation that composes an overlay — the usual way,
# and the way `runs_service` in `lib/common.sh` assumes — would compose without
# it here. Every service only the overlay defines then falls out of the set, and
# `--remove-orphans` on this very line removes its container: an object store, a
# second Runner, whatever that installation added. `update.sh` starts the stack
# with a bare `compose up`, and this is now the same.
log "starting the recorded images"
if ! (
    COMPOSE_FILE="${COMPOSE_FILE:-compose.yaml}:$override"
    export COMPOSE_FILE
    compose up -d --remove-orphans
); then
    die "could not start the recorded images. They may have been pruned — check
       \`docker images\`. state/current.lock still names them."
fi

if wait_healthy 120; then
    log "back on the previous images and healthy."
    $from_update || "$ROOT/scripts/maintenance.sh" off
    log "**The override at state/rollback.compose.yaml is what pins them.** It is not
       read by a plain \`docker compose up\`, so bring the stack up with both files
       until the cause is fixed:
         COMPOSE_FILE=\"\$COMPOSE_FILE:state/rollback.compose.yaml\" docker compose up -d"
    exit 0
fi

die "the previous images did not come back healthy either. This is not something
       a script should keep trying. \`docker compose logs\` and somebody awake."
