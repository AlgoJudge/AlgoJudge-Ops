#!/usr/bin/env bash
#
# Pulls, checks whether anything actually changed, backs up, and swaps — with
# the download outside the outage.
#
#     ./scripts/update.sh
#     ./scripts/update.sh --no-git       do not touch this repository
#     ./scripts/update.sh --dry-run      say what would happen
#
# **The order is the point.** Pulling images is the long step and costs no
# downtime, so it happens first; the window is only steps 5 to 8, which with
# working health checks is seconds. An update that found nothing new stops before
# it closes anything.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

load_env
lock

git_pull=true
dry_run=false
for argument in "$@"; do
    case "$argument" in
        --no-git) git_pull=false ;;
        --dry-run) dry_run=true ;;
        *) die "unknown argument: $argument" ;;
    esac
done

LOCK_FILE="$ROOT/state/current.lock"

# The digest each service is running right now, one `service repo@sha256:…` per
# line. This is what a rollback restores.
#
# **`RepoDigests`, not `Config.Image`.** The container's `Config.Image` is the
# *reference* it was created from — `…/algojudge-server:0` — and writing that
# down produces a lock file whose rollback restores whatever that moving tag
# points at **now**, which is precisely the image being rolled back from.
#
# The fallback is the local image id, for an image built on this host and never
# pushed anywhere. It pins correctly here and cannot be pulled elsewhere, which
# is the honest limit of a digest that no registry has.
digests() {
    local service id reference digest
    for service in server client runner external-runner; do
        id=$(compose ps -q "$service" 2>/dev/null | head -1)
        [ -n "$id" ] || continue
        reference=$(docker inspect --format '{{.Config.Image}}' "$id" 2>/dev/null)
        digest=$(docker image inspect --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' \
            "$reference" 2>/dev/null)
        [ -n "$digest" ] || digest=$(docker inspect --format '{{.Image}}' "$id" 2>/dev/null)
        printf '%s %s\n' "$service" "$digest"
    done
}

# ── 1. The repository ───────────────────────────────────────────────────────
#
# **This brings new compose files and scripts, never new image versions.** Those
# are tags in `.env`, which belongs to the installation and is not in the
# repository. The decision — why digests in Git do not apply to a product many
# people deploy independently — is `docs/specs/DEPLOYMENT.md` in the AlgoJudge
# workspace, not a path in this repository.

if $git_pull && [ -d "$ROOT/.git" ]; then
    log "updating the repository"
    if ! git -C "$ROOT" pull --ff-only; then
        warn "git pull --ff-only failed. Local changes, or a rewritten branch. Carrying
       on with the files as they are — nothing here needs the repository to be
       current."
    fi
fi

# ── 2. The images ───────────────────────────────────────────────────────────

log "pulling images (no downtime yet)"
$dry_run || compose pull --quiet

# **The four language images by hand, because `compose pull` does not reach
# them.** They are not services -- they are values the Runner is given, and it
# starts each judged run in one of them. Two facts make the omission silent:
# the Runner pulls an image only when the host does not have it at all, and it
# probes each image once and remembers the answer for its lifetime. So an
# installation updated without this keeps last year's toolchain for ever, with
# every container new and nothing to see. Measured 2026-09-08.
if runs_service runner-1 runner; then
    for lang in gcc clang python pypy; do
        image="${REGISTRY:-ghcr.io/algojudge}/lang-$lang:${RUNNER_TAG:-0}"
        log "pulling $image"
        $dry_run || docker pull --quiet "$image" >/dev/null || warn "could not pull $image;
       the Runner will keep using the copy this host already has"
    done
fi

# **Compared as image ids, because a moving tag is the normal case.**
# `SERVER_TAG=0` points at a different image after every release, so "is the tag
# the same" would answer yes for ever.
#
# **Asked of the containers, not of `compose config --images`.** That command
# returns a service's image *and its dependencies'* — `config --images server`
# prints `postgres:18` first — so taking the first line compares the Server
# against the database and reports an update on every run.
#
# **Only the services this installation actually selects.** A service no active
# profile names has no container, and the branch below reads "no container" as
# "not started yet, so starting it is the update" — which on a host without the
# `external-runner` profile would report a change on every single run and close
# the installation for nothing. Asked of Compose, so this loop and `compose.yaml`
# cannot come to disagree about what is selected.
selected=$(compose config --services 2>/dev/null)
[ -n "$selected" ] || die "docker compose config --services returned nothing. There is no
       way to tell which services this installation runs, and guessing is how an
       update closes a stack it should have left alone."

changed=""
for service in server client runner external-runner; do
    printf '%s
' "$selected" | grep -qxF "$service" || continue

    id=$(compose ps -q "$service" 2>/dev/null | head -1)
    if [ -z "$id" ]; then
        # Selected but not running: starting it is the update.
        changed="$changed $service(new)"
        continue
    fi
    reference=$(docker inspect --format '{{.Config.Image}}' "$id" 2>/dev/null)
    was=$(docker inspect --format '{{.Image}}' "$id" 2>/dev/null)
    now=$(docker image inspect --format '{{.Id}}' "$reference" 2>/dev/null || echo "$was")
    if [ "$was" != "$now" ]; then
        changed="$changed $service"
        log "  $service: ${was#sha256:} -> ${now#sha256:}"
    fi
done

if [ -z "$changed" ]; then
    log "nothing new. Not closing anything."
    exit 0
fi

log "new images for:$changed"

if $dry_run; then
    log "--dry-run: stopping here."
    exit 0
fi

# ── 3. The backup ───────────────────────────────────────────────────────────
#
# **Before the swap, and before any migration.** With `MIGRATE_ON_START=true` the
# new Server brings the schema forward as it starts, and a schema change is not
# undone by putting the old image back. This dump is what makes step 8 mean
# something.

schema_before=$(psql_scalar "SELECT string_agg(\"MigrationId\", ',' ORDER BY \"MigrationId\") FROM \"__EFMigrationsHistory\"" | tr -d '[:space:]' || true)

log "backing up before the swap"
"$ROOT/scripts/backup.sh" --pre-update || die "the pre-update backup failed. Nothing
       was updated: an update with no backup in front of it is not one this
       script will do."

# **Where the backup actually went, not where it usually goes.** `backup.sh`
# honours `BACKUP_DIR`; looking in `$ROOT/backups` regardless records an empty
# `dump_before` for an installation that moved its backups — and `rollback.sh`
# prints that as the recovery command, at the one moment after a migration when
# it is the only way back. A missing directory is worse: `find` fails, `set -euo
# pipefail` ends the script with no message at all, immediately after the dump
# was taken.
pre_update_dump=$(find "$(backup_dir)" -maxdepth 1 -name 'algojudge-*.dump' -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | head -1 | cut -d' ' -f2- || true)

if [ -z "$pre_update_dump" ]; then
    die "the backup reported success and no dump is in $(backup_dir). Refusing to
       go on: the update would have nothing to roll back to, and would say so only
       after it had already swapped the images."
fi

# ── 4. The window ───────────────────────────────────────────────────────────

log "closing the installation"
"$ROOT/scripts/maintenance.sh" on "update" --wait-closed

# ── 5. The swap ─────────────────────────────────────────────────────────────

log "starting the new images"
compose up -d --remove-orphans

# ── 6. Did it work ──────────────────────────────────────────────────────────

if wait_healthy 120; then
    log "healthy"

    printf '%s\n' "$(digests)" >"$LOCK_FILE"
    log "digests recorded in state/current.lock — this is what rollback.sh restores"

    schema_after=$(psql_scalar "SELECT string_agg(\"MigrationId\", ',' ORDER BY \"MigrationId\") FROM \"__EFMigrationsHistory\"" | tr -d '[:space:]' || true)
    if [ "$schema_before" != "$schema_after" ]; then
        # **Written down where a rollback will read it.** Putting the old image
        # back does not undo a migration, and somebody rolling back at three in
        # the morning should be told that by the tool rather than discover it.
        {
            printf 'migrated_at=%s\n' "$(date -Iseconds)"
            printf 'from=%s\n' "$schema_before"
            printf 'to=%s\n' "$schema_after"
            printf 'dump_before=%s\n' "$pre_update_dump"
        } >"$ROOT/state/last-migration"
        log "the schema moved. state/last-migration records it, and the dump taken
       before it is $(basename "$pre_update_dump")."
    else
        rm -f "$ROOT/state/last-migration"
    fi

    "$ROOT/scripts/maintenance.sh" off

    # Only images this project has stopped using. Never a global prune: the host
    # may run other things, and `docker system prune` does not know that.
    log "removing images this project no longer uses"
    prune_our_images >/dev/null || true

    log "updated."
    exit 0
fi

# ── 7. It did not ───────────────────────────────────────────────────────────

warn "the stack did not come back healthy within 120s. Rolling back."
compose logs --no-color --tail 50 server >"$ROOT/state/failed-update.log" 2>&1 || true

if "$ROOT/scripts/rollback.sh" --from-update; then
    "$ROOT/scripts/maintenance.sh" off || true
    die "rolled back to the previous images. The Server's last 50 log lines are in
       state/failed-update.log. Nothing was lost."
fi

"$ROOT/scripts/maintenance.sh" off || true
die "the update failed AND the rollback failed. The installation is closed and
       needs somebody. state/failed-update.log has the Server's last words, and
       $(basename "${pre_update_dump:-the pre-update dump}") is the database as it
       was before any of this."
