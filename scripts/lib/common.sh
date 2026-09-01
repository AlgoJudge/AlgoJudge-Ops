#!/usr/bin/env bash
#
# What every script here shares: the repository root, `.env`, logging, a lock,
# and the two ways of asking the stack a question.
#
# **A shared file rather than a copy per script**, unlike the workspace's own
# `scripts/`, where the argument for copying is that each has to be runnable
# from a fresh clone with nothing installed. That does not apply here: these are
# cloned together, run from the same directory, and already depend on
# `compose.yaml` sitting beside them.
#
# Sourced, never executed:
#
#     . "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

# Nothing here calls `set -e` on the caller's behalf. Each script decides,
# because two of them treat a non-zero exit as a normal outcome.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT
cd "$ROOT"

# The script's own name, prefixed onto every line it prints, so a line in
# `/var/log/algojudge/` says which of five scripts wrote it.
ME="$(basename "${BASH_SOURCE[1]:-algojudge}" .sh)"
readonly ME

# ── Saying things ───────────────────────────────────────────────────────────
#
# **Both clocks on every line.** The schedule is anchored to the host's local
# time and the Server's own collector is anchored to UTC, so a support question
# months later — "what time did the backup actually run" — is answerable from
# the log rather than from a guess about what the machine's zone was in March.

log() { printf '%s [%s] %s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$(date -u '+%H:%MZ')" "$ME" "$*"; }
warn() { log "WARNING: $*" >&2; }
die() { log "ERROR: $*" >&2; exit 1; }

# ── Configuration ───────────────────────────────────────────────────────────

# Reads `.env` into the environment.
#
# **`set -a` rather than a parser.** Compose reads this file itself and these
# scripts must agree with it about what it says; writing a second reader is
# writing a second opinion. The cost is that `.env` has to be shell-legal, which
# `.env.example` is and which `preflight.sh` checks.
load_env() {
    [ -f "$ROOT/.env" ] || die "no .env — copy .env.example to .env and fill it in"
    set -a
    # shellcheck disable=SC1091
    . "$ROOT/.env"
    set +a
}

# The value of one variable, or a default. Used where a script wants a setting
# without insisting the operator wrote it out.
setting() {
    local name=$1 fallback=${2-}
    local value=${!name-}
    printf '%s' "${value:-$fallback}"
}

require() {
    local name=$1
    [ -n "${!name-}" ] || die "$name is not set in .env — see .env.example"
}

# ── Tidying up ──────────────────────────────────────────────────────────────
#
# **One `trap`, and everything registers with it.** `trap … EXIT` *replaces* the
# handler rather than adding to it, so two pieces of code each setting their own
# means the first one silently stops running — and the first one here is the
# release of the lock, which would then be left behind on every backup that took
# a temporary file. A registry costs six lines and removes the whole class.

_cleanup_actions=()

add_cleanup() { _cleanup_actions+=("$1"); }

_run_cleanup() {
    local status=$?
    local index
    # Backwards: the last thing set up is the first thing undone.
    for ((index = ${#_cleanup_actions[@]} - 1; index >= 0; index--)); do
        eval "${_cleanup_actions[index]}" || true
    done
    _cleanup_actions=()
    return $status
}

trap _run_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ── One at a time ───────────────────────────────────────────────────────────

# **One at a time, so a backup and an update never overlap.** The nightly backup
# at 04:00 and the update at 04:15 are fifteen minutes apart on paper and not at
# all on a large database.
#
# One lock for all of them rather than one each: the reason they must not overlap
# is that they touch the same containers and the same database, so a per-script
# lock would let exactly the pair that matters run together.
#
# **Two implementations, because `flock` is not everywhere.** It is util-linux,
# so a Linux host — the deployment target — has it, and Git Bash on a Windows
# workstation does not. The first version called `flock` unconditionally and
# reported a missing command as *another script is running*, which is a lie in
# the one situation where somebody is already confused. Found 2026-08-30 on the
# first real run.
#
# The fallback is `mkdir`, which is atomic on every filesystem worth having: the
# directory is the lock, and the pid inside it is what makes a lock left by a
# killed script recoverable rather than permanent.
lock() {
    local file="$ROOT/state/algojudge.lock"

    # **Held once per run, not once per script.** `update.sh` takes the lock and
    # then calls `backup.sh`, which takes the same one — so without this the
    # update deadlocks against itself and reports *another maintenance script is
    # running*, naming its own parent's pid. Found 2026-08-30 on the first real
    # update, at the step whose whole purpose is to make an update safe.
    #
    # Exported, so it reaches a child script; checked against this process tree's
    # own marker rather than merely "is it set", so a stale value inherited from
    # somewhere else cannot wave a script through.
    if [ "${ALGOJUDGE_LOCK_HELD-}" = "$file" ]; then
        return
    fi
    export ALGOJUDGE_LOCK_HELD="$file"

    if command -v flock >/dev/null 2>&1; then
        exec 9>"$file" || die "cannot write $file"
        flock -n 9 || die "another AlgoJudge maintenance script is running (lock: $file)"
        return
    fi

    local dir="$file.d"
    if ! mkdir "$dir" 2>/dev/null; then
        local held
        held=$(cat "$dir/pid" 2>/dev/null || echo "")
        # **A pid on its own is not evidence** — it can be released and handed to
        # something else — but a pid that is not running at all is proof enough
        # that whatever held this lock is gone.
        if [ -n "$held" ] && kill -0 "$held" 2>/dev/null; then
            die "another AlgoJudge maintenance script is running (pid $held, lock: $dir)"
        fi
        warn "taking over a lock left by pid ${held:-unknown}, which is no longer running"
        rm -rf "$dir"
        mkdir "$dir" || die "cannot take the lock at $dir"
    fi
    printf '%s\n' "$$" >"$dir/pid"

    # Released on every exit path, through the registry above rather than a
    # `trap` of its own — which anything setting a later one would silently
    # replace.
    add_cleanup "rm -rf '$dir'"
}

# ── Talking to the stack ────────────────────────────────────────────────────

compose() { docker compose --project-directory "$ROOT" "$@"; }

# Runs `aj-admin` inside the Server's container.
#
# **This is the only supported way to reach the operator's surface.** It answers
# on the Server's own loopback interface and asks for a token it reads from its
# own environment — so it never enters shell history, and publishing a port
# would not open it: the connection arrives as the bridge gateway.
#
# `-T` because these are scripts: with a TTY allocated, output is line-ending
# mangled and a non-interactive cron run fails outright.
aj_admin() { compose exec -T server aj-admin "$@"; }

# **The `image.source` label each release workflow sets, one per repository.**
#
# `docker image prune --filter label=key=value` matches the value **exactly**,
# and the workflows set `<server>/<owner>/<repo>` — so the organisation's URL on
# its own matched nothing at all, and every prune this repository ran reclaimed
# not one image. Measured 2026-09-01 against an image carrying the real label.
#
# Four repositories cover all eight images: the Runner's own workflow builds and
# labels its four `lang-*` images too.
AJ_IMAGE_SOURCES="AlgoJudge-Server AlgoJudge-Client AlgoJudge-Runner AlgoJudge-External-Runner"

# Removes images this project has stopped using, and nothing else. Prints one
# line per repository that gave something back, and nothing for the rest.
prune_our_images() {
    local repository reclaimed
    for repository in $AJ_IMAGE_SOURCES; do
        reclaimed=$(docker image prune -f \
            --filter "label=org.opencontainers.image.source=https://github.com/AlgoJudge/$repository" \
            2>/dev/null | tail -1)
        case "$reclaimed" in
            "" | *"0B"*) : ;;
            *) printf '  %s: %s\n' "$repository" "$reclaimed" ;;
        esac
    done
}

# Whether the `server` service is running here at all. A Runner-only host has no
# Server to ask, and several scripts have a different answer in that case rather
# than an error.
have_server() { [ -n "$(compose ps -q server 2>/dev/null)" ]; }

# Waits until every started service reports healthy.
#
# **Asks Compose rather than polling an endpoint**, so it uses the health checks
# the images already define — the Server's over `/api/v1/health`, the Client's
# over its own root, PostgreSQL's `pg_isready`. A second definition here would be
# a second thing to keep true.
wait_healthy() {
    local timeout=${1:-120} waited=0
    while [ "$waited" -lt "$timeout" ]; do
        # **`-a`, and a delimiter that cannot appear in a value.** Two things
        # made the first version of this report a crash-looping container as
        # healthy, and both had to be fixed together:
        #
        #   * without `-a`, a container that has **exited** is not listed at
        #     all, so nothing here could see it;
        #   * with the default field separator, a service whose image declares
        #     **no health check** collapses its empty Health column, State
        #     lands in `$2`, and every test below reads the wrong field.
        #
        # Both Runners have no health check, so the second was not theoretical:
        # `up --wait` reported them healthy while one was failing to sign in.
        # Measured 2026-09-01.
        if ! compose ps -a --format '{{.Service}}|{{.Health}}|{{.State}}' \
            | awk -F'|' '
                  # Anything not running is not healthy: restarting, exited,
                  # dead, created, paused.
                  $3 != "running" { bad = 1 }
                  # Running and declaring health: it has to say healthy.
                  # Running and declaring none is a pass — that is either
                  # Runner, and refusing it would block every `up` here.
                  $3 == "running" && $2 != "" && $2 != "healthy" { bad = 1 }
                  END { exit bad }
              '; then
            sleep 3
            waited=$((waited + 3))
            continue
        fi
        # Nothing running is not healthy, it is nothing.
        [ -n "$(compose ps -q)" ] || return 1
        return 0
    done
    return 1
}

# ── The database ────────────────────────────────────────────────────────────

# Runs one psql command against the stack's own database, quietly, printing only
# the value. Used for sizes and for reading the migration history.
psql_scalar() {
    compose exec -T postgres psql \
        -U "$(setting POSTGRES_USER algojudge)" \
        -d "$(setting POSTGRES_DB algojudge)" \
        -tAc "$1"
}

# ── Bytes ───────────────────────────────────────────────────────────────────

# Human-readable, for a log line an operator reads rather than parses.
human_bytes() {
    local bytes=$1
    if [ "$bytes" -ge 1073741824 ]; then
        printf '%s.%s GiB' "$((bytes / 1073741824))" "$(((bytes % 1073741824) * 10 / 1073741824))"
    elif [ "$bytes" -ge 1048576 ]; then
        printf '%s MiB' "$((bytes / 1048576))"
    else
        printf '%s KiB' "$((bytes / 1024))"
    fi
}
