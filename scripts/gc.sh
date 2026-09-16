#!/usr/bin/env bash
#
# Reclaims what this installation left behind, and nothing that belongs to
# anybody else.
#
#     ./scripts/gc.sh
#
# **Every prune here is filtered to this project.** `docker system prune` and
# `docker volume prune` do not know that the host may run other things, and
# would take somebody's unrelated volume or image with them.
#
# **`VACUUM` and `REINDEX` are deliberately not here.** A `REINDEX` holds locks
# a contest would notice, and PostgreSQL's autovacuum already does the routine
# part.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

load_env
lock

RETENTION=$(setting GC_TMP_RETENTION_DAYS 7)

# ── The Runners' scratch ────────────────────────────────────────────────────
#
# **Strays are normal, not a defect.** A Runner killed mid-evaluation cannot
# clean up after itself, and the job it was doing goes back on the queue by
# lease. **Nothing else removes them**: a Runner empties the one directory it
# is about to use and no other, and the job it dropped is usually re-claimed by
# a different Runner, whose scratch is somewhere else entirely.
#
# **A whole day of margin, and that is the point of the units.** An evaluation
# takes minutes; deleting a directory a Runner is still using would fail an
# evaluation that was going to succeed.

work=${RUNNER_WORK_DIR:-}
if [ -n "$work" ] && [ -d "$work" ]; then
    # **The directories overlay**, where the scratch is one host directory with
    # a directory per Runner under it and this shell can reach all of it.
    removed=$(find "$work" -mindepth 1 -maxdepth 1 -type d -mtime "+$RETENTION" -print 2>/dev/null | wc -l)
    if [ "$removed" -gt 0 ]; then
        find "$work" -mindepth 1 -maxdepth 1 -type d -mtime "+$RETENTION" -exec rm -rf {} + 2>/dev/null
        log "removed $removed work director(y|ies) older than $RETENTION days"
    fi
else
    # **The default, where each Runner's scratch is a volume of its own** and
    # has no path this shell can open. Swept from inside a throwaway container
    # instead, one per Runner.
    #
    # **The volume is read off the running container rather than named here.**
    # Compose prefixes a volume with the project name, which an installation may
    # set; asking the container that has it mounted needs no guess and skips a
    # Runner this host does not run. It also cannot bring one into existence by
    # naming it, which `docker run -v` would.
    sweeper="nginx:$(setting NGINX_TAG 1.27-alpine)"   # as `preflight.sh` probes with
    for n in 1 2 3 4; do
        container=$(compose ps -q "runner-$n" 2>/dev/null) || continue
        [ -n "$container" ] || continue
        volume=$(docker inspect -f \
            '{{range .Mounts}}{{if eq .Destination "/var/lib/algojudge-runner/work"}}{{.Name}}{{end}}{{end}}' \
            "$container" 2>/dev/null)
        [ -n "$volume" ] || continue
        removed=$(MSYS_NO_PATHCONV=1 docker run --rm -u 0:0 -v "$volume:/work" "$sweeper" \
            sh -c "find /work -mindepth 1 -maxdepth 1 -type d -mtime +$RETENTION -print | wc -l" \
            2>/dev/null | tr -d '[:space:]')
        case "${removed:-0}" in ''|*[!0-9]*) continue ;; 0) continue ;; esac
        MSYS_NO_PATHCONV=1 docker run --rm -u 0:0 -v "$volume:/work" "$sweeper" \
            sh -c "find /work -mindepth 1 -maxdepth 1 -type d -mtime +$RETENTION -exec rm -rf {} +" \
            >/dev/null 2>&1
        log "removed $removed work director(y|ies) older than $RETENTION days from $volume"
    done
fi

# ── Job containers nobody collected ─────────────────────────────────────────
#
# The Runner sweeps its own siblings when it restarts. This catches the case it
# cannot: a Runner that was removed rather than restarted, so nothing of its own
# ever runs again to tidy up.
#
# **By label, not by name.** A sandbox is named `algojudge-<pid>-<random>` and
# carries `algojudge.sandbox=1` (`aj-sandbox/src/docker.rs`); `--filter name=` is
# a substring match, not an anchored one, so a name filter would miss ours and
# reach somebody else's containers instead.
#
# `status=exited` stays: a sandbox that is still running belongs to a Runner
# that is still using it.
strays=$(docker ps -aq --filter "status=exited" --filter "label=algojudge.sandbox=1" 2>/dev/null | wc -l)
if [ "$strays" -gt 0 ]; then
    docker ps -aq --filter "status=exited" --filter "label=algojudge.sandbox=1"         | xargs -r docker rm -f >/dev/null 2>&1
    log "removed $strays exited job container(s)"
fi

# ── Images ──────────────────────────────────────────────────────────────────

if [ "$(setting GC_PRUNE_IMAGES true)" = "true" ]; then
    # **Filtered per repository**, because a label filter matches its value
    # exactly and every image carries its own `<owner>/<repo>`.
    reclaimed=$(prune_our_images)
    if [ -n "$reclaimed" ]; then
        log "images:"
        printf '%s\n' "$reclaimed"
    else
        log "images: nothing to reclaim"
    fi
fi

# ── Logs ────────────────────────────────────────────────────────────────────
#
# These scripts' own logs, wherever the crontab points them. Container logs are
# not this loop's business and never were: `compose.yaml` bounds them itself,
# with a `logging:` block on every service and `LOG_MAX_SIZE`/`LOG_MAX_FILES` in
# `.env`. The daemon's own default is unbounded, which is why the stack does not
# rely on it.

for logfile in /var/log/algojudge/*.log; do
    [ -f "$logfile" ] || continue
    size=$(stat -c '%s' "$logfile")
    if [ "$size" -gt $((32 * 1024 * 1024)) ]; then
        mv "$logfile" "$logfile.1"
        : >"$logfile"
        log "rotated $(basename "$logfile") at $(human_bytes "$size")"
    fi
done

# ── The backup directory ────────────────────────────────────────────────────
#
# **Only if backup.sh has not run today.** Rotation belongs to the script that
# writes the dumps; this is the safety net for an installation whose backups are
# turned off but whose directory still holds history.

newest=$(find "$(setting BACKUP_DIR "$ROOT/backups")" -maxdepth 1 -name 'algojudge-*.dump' -mtime -1 2>/dev/null | head -1)
if [ -z "$newest" ]; then
    log "no dump in the last day — rotation is backup.sh's, and it has not run.
       Not rotating anything here: a directory nobody is adding to is not the
       thing to start deleting from."
fi

log "done."
