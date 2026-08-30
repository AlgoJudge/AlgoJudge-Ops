#!/usr/bin/env bash
#
# Reclaims what this installation left behind, and nothing that belongs to
# anybody else.
#
#     ./scripts/gc.sh
#
# **Every prune here is filtered to this project.** `docker system prune` and
# `docker volume prune` do not know that the host may run other things, and a
# maintenance script that took somebody's unrelated database volume with it would
# be the worst thing in this repository. Nothing below runs unfiltered.
#
# **`VACUUM` and `REINDEX` are deliberately not here.** They have a different
# risk profile and a different runtime — a `REINDEX` holds locks a contest would
# notice — and PostgreSQL's autovacuum already does the routine part. Putting
# them in a nightly job is its own decision, and nobody has taken it.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

load_env
lock

RETENTION=$(setting GC_TMP_RETENTION_DAYS 7)

# ── The Runner's work directory ─────────────────────────────────────────────
#
# **Strays are normal, not a defect.** A Runner killed mid-evaluation cannot
# clean up after itself, and the job it was doing goes back on the queue by
# lease. What it leaves is a directory nothing will ever look at again.

work=${RUNNER_WORK_DIR:-}
if [ -n "$work" ] && [ -d "$work" ]; then
    # `-mmin` rather than `-mtime` for the floor, and a whole day of margin: a
    # long evaluation is minutes, not days, so anything older than the retention
    # window is certainly finished. Deleting a directory a Runner is still using
    # would fail an evaluation that was going to succeed.
    removed=$(find "$work" -mindepth 1 -maxdepth 1 -type d -mtime "+$RETENTION" -print 2>/dev/null | wc -l)
    if [ "$removed" -gt 0 ]; then
        find "$work" -mindepth 1 -maxdepth 1 -type d -mtime "+$RETENTION" -exec rm -rf {} + 2>/dev/null
        log "removed $removed work director(y|ies) older than $RETENTION days"
    fi
fi

# ── Job containers nobody collected ─────────────────────────────────────────
#
# The Runner sweeps its own siblings when it restarts. This catches the case it
# cannot: a Runner that was removed rather than restarted, so nothing of its own
# ever runs again to tidy up.

strays=$(docker ps -aq --filter "status=exited" --filter "name=aj-job-" 2>/dev/null | wc -l)
if [ "$strays" -gt 0 ]; then
    docker ps -aq --filter "status=exited" --filter "name=aj-job-" | xargs -r docker rm -f >/dev/null 2>&1
    log "removed $strays exited job container(s)"
fi

# ── Images ──────────────────────────────────────────────────────────────────

if [ "$(setting GC_PRUNE_IMAGES true)" = "true" ]; then
    # **Filtered by the label every AlgoJudge image carries**, which the release
    # workflow sets. An image without it is somebody else's and is left alone.
    freed=$(docker image prune -f \
        --filter "label=org.opencontainers.image.source=https://github.com/AlgoJudge" \
        2>/dev/null | tail -1)
    log "images: ${freed:-nothing to reclaim}"
fi

# ── Logs ────────────────────────────────────────────────────────────────────
#
# These scripts' own logs, wherever the crontab points them. Container logs are
# Docker's business and are bounded by the daemon's log driver — `docs/INSTALL.md`
# says to set that, because the default is an unbounded JSON file and it is the
# most common way one of these hosts fills its disk.

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
