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

# **Every service this installation runs that carries an image of ours.**
#
# `runner` is not one of them. `compose.yaml` defines `runner-1` ... `runner-N`,
# so the literal `runner` this file used matched no service: every Runner went
# uncompared and unrecorded. A release that moved only the Runner read as
# "nothing new", and a rollback had no Runner image to go back to. Measured
# 2026-09-08.
product_services() {
    compose config --services 2>/dev/null |
        grep -E '^(server|client|external-runner|runner-[0-9]+)$' || true
}

# The four language images. They are not services -- they are values the Runner
# is handed -- so nothing built on `compose` sees them at all.
LANGS="gcc clang python pypy"

lang_image() { printf '%s/lang-%s:%s\n' "${REGISTRY:-ghcr.io/algojudge}" "$1" "${RUNNER_TAG:-0}"; }

lang_key() {
    case $1 in
        gcc) printf 'Gcc' ;; clang) printf 'Clang' ;;
        python) printf 'Python' ;; pypy) printf 'Pypy' ;;
    esac
}

judges_here() { product_services | grep -q '^runner-'; }

# The repository a service's own image is named after, as it appears in a
# reference: leading slash and trailing colon, because `algojudge-runner` is a
# substring of `algojudge-external-runner` and a plain match would take the wrong
# line.
image_name() {
    case $1 in
        server) printf '/algojudge-server:' ;;
        client) printf '/algojudge-client:' ;;
        external-runner) printf '/algojudge-external-runner:' ;;
        runner-*) printf '/algojudge-runner:' ;;
    esac
}

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
    local service id reference digest lang
    for service in $(product_services); do
        id=$(compose ps -q "$service" 2>/dev/null | head -1)
        [ -n "$id" ] || continue
        reference=$(docker inspect --format '{{.Config.Image}}' "$id" 2>/dev/null)
        digest=$(docker image inspect --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' \
            "$reference" 2>/dev/null)
        [ -n "$digest" ] || digest=$(docker inspect --format '{{.Image}}' "$id" 2>/dev/null)
        printf '%s %s\n' "$service" "$digest"
    done

    # **`lang:` lines, and `rollback.sh` reads them as environment rather than as
    # services.** A Runner put back without the language images it was released
    # with is the one combination `AlgoJudge-Runner`'s README tells operators not
    # to run, and nothing would catch it: the Runner checks that an image carries
    # `aj-shim`, never which version.
    if judges_here; then
        for lang in $LANGS; do
            reference=$(lang_image "$lang")
            digest=$(docker image inspect --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' \
                "$reference" 2>/dev/null)
            [ -n "$digest" ] || digest=$(docker image inspect --format '{{.Id}}' "$reference" 2>/dev/null)
            [ -n "$digest" ] || continue
            printf 'lang:%s %s\n' "$lang" "$digest"
        done
    fi
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
if judges_here; then
    for lang in $LANGS; do
        image=$(lang_image "$lang")
        log "pulling $image"
        $dry_run || docker pull --quiet "$image" >/dev/null || warn "could not pull $image;
       the Runner will keep using the copy this host already has"
    done
fi

# **Compared as image ids, because a moving tag is the normal case.**
# `SERVER_TAG=0` points at a different image after every release, so "is the tag
# the same" would answer yes for ever.
#
# **Against what Compose would run, not against what the container came from.**
# `.Config.Image` is the reference this container was *created* from, and asking
# whether that has moved answers only half the question. It is right for a moving
# tag: `SERVER_TAG=0` names a new image after every release. It is silent for the
# other arrangement this stack documents — an operator who pins `0.1.0` and later
# writes `0.1.1` — because `0.1.0` has not moved, so the update reported "nothing
# new" while the image it had just pulled sat unused. Measured 2026-09-08.
#
# `config --images <service>` returns the service's image **and its
# dependencies'**, and **the order is not something to rely on**: measured
# 2026-09-08, Compose v5.3.1 prints `algojudge-server:0` before `postgres:18`
# and v5.4.0 prints them the other way round. Taking the first line therefore
# compared the Server against the database on one of the two, and reported an
# update on every single run. The line is picked by the repository the service's
# image is named after instead, and an answer that matches nothing falls back to
# the reference the container carries — which is exactly what this did before.
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
for service in $(product_services); do
    id=$(compose ps -q "$service" 2>/dev/null | head -1)
    if [ -z "$id" ]; then
        # Selected but not running: starting it is the update.
        changed="$changed $service(new)"
        continue
    fi
    reference=$(compose config --images "$service" 2>/dev/null |
        grep -m1 -F "$(image_name "$service")")
    [ -n "$reference" ] || reference=$(docker inspect --format '{{.Config.Image}}' "$id" 2>/dev/null)
    was=$(docker inspect --format '{{.Image}}' "$id" 2>/dev/null)
    now=$(docker image inspect --format '{{.Id}}' "$reference" 2>/dev/null || echo "$was")
    if [ "$was" != "$now" ]; then
        changed="$changed $service"
        log "  $service: ${was#sha256:} -> ${now#sha256:}"
    fi
done

# **The language images, compared against what the last update recorded.** They
# are not services, so the loop above cannot see them, and a Runner probes each
# image once and remembers the answer for its lifetime -- so a new one is picked
# up only when the Runner container is recreated, which is what `changed` causes.
if [ -s "$LOCK_FILE" ] && judges_here; then
    for lang in $LANGS; do
        was=$(grep -m1 "^lang:$lang " "$LOCK_FILE" | cut -d' ' -f2-)
        [ -n "$was" ] || continue
        reference=$(lang_image "$lang")
        now=$(docker image inspect --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' \
            "$reference" 2>/dev/null)
        [ -n "$now" ] || now=$(docker image inspect --format '{{.Id}}' "$reference" 2>/dev/null || true)
        if [ -n "$now" ] && [ "$was" != "$now" ]; then
            changed="$changed lang-$lang"
            log "  lang-$lang: ${was##*@} -> ${now##*@}"
        fi
    done
fi

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
