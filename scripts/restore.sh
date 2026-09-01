#!/usr/bin/env bash
#
# Puts a dump back, with the installation closed and the consequences stated
# first.
#
#     ./scripts/restore.sh backups/algojudge-20260830-040000.dump
#     ./scripts/restore.sh --yes backups/algojudge-20260830-040000.dump
#
# **Written together with `backup.sh` rather than after it.** A backup with no
# tested restore procedure is a hypothesis, and the first time anybody finds out
# is the worst possible time.
#
# **This destroys the current database.** `pg_restore --clean --if-exists` drops
# every object the dump carries before recreating it, so what is in the
# installation now is gone. It asks first unless told not to.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

load_env
lock

confirm=true
dump=""
while [ $# -gt 0 ]; do
    case "$1" in
        --yes) confirm=false ;;
        -*) die "unknown argument: $1" ;;
        *) dump=$1 ;;
    esac
    shift
done

[ -n "$dump" ] || die "usage: restore.sh [--yes] <dump file>"
[ -f "$dump" ] || die "no such file: $dump"

have_server || die "no stack here. Bring one up first — on a clean host that is
       \`docker compose up -d --wait\`, and then this."

# ── What is in the file ─────────────────────────────────────────────────────

meta="$dump.meta"
if [ -f "$meta" ]; then
    log "the dump says:"
    sed 's/^/       /' "$meta"

    recorded=$(grep -m1 '^sha256=' "$meta" | cut -d= -f2 || true)
    if [ -n "$recorded" ]; then
        actual=$(sha256sum "$dump" | cut -d' ' -f1)
        [ "$recorded" = "$actual" ] || die "the dump does not match the checksum recorded
       beside it. It has been altered or damaged since it was taken; do not
       restore it without knowing why."
    fi

    coverage=$(grep -m1 '^coverage=' "$meta" | cut -d= -f2- || true)
    case "$coverage" in
        INCOMPLETE*) warn "$coverage
       Restoring this alone gives an installation whose rows point at bytes that
       are not there. Restore the file store from the same window too." ;;
    esac
else
    warn "no .meta beside this dump, so nothing can be checked before restoring:
       not its checksum, not which schema it holds, not whether it covered the
       files. Continuing is a decision."
fi

# ── The schema, which is the step that actually bites ───────────────────────
#
# **An old dump under a newer Server is not an error, it is a migration.** With
# `MIGRATE_ON_START=true` the Server brings the restored schema forward on its
# next start — which is usually what somebody restoring last week's backup wants,
# and is a very unpleasant surprise if it is not. Either way it is one-way: there
# is no going back down.

if [ -f "$meta" ]; then
    was=$(grep -m1 '^schema=' "$meta" | cut -d= -f2 || true)
    now=$(psql_scalar "SELECT string_agg(\"MigrationId\", ',' ORDER BY \"MigrationId\") FROM \"__EFMigrationsHistory\"" | tr -d '[:space:]' || true)
    if [ -n "$was" ] && [ -n "$now" ] && [ "$was" != "$now" ]; then
        warn "the dump holds a different schema from the running installation.
       dump:    $was
       running: $now
       With MIGRATE_ON_START=$(setting MIGRATE_ON_START true) the Server will migrate the restored
       database forward when it starts. That is one-way. If you meant to go back
       to an older Server as well, set SERVER_TAG to its version first."
    fi
fi

if $confirm; then
    printf 'This DESTROYS the current database and replaces it with %s.\n' "$(basename "$dump")"
    printf 'Type the word restore to continue: '
    read -r answer
    [ "$answer" = "restore" ] || die "not confirmed; nothing was touched."
fi

# ── Doing it ────────────────────────────────────────────────────────────────
#
# The Server and the Client stop; PostgreSQL stays up, because it is what is
# being restored into. Stopping rather than draining: nothing should hold a
# connection to a database whose tables are being dropped.

log "closing the installation"
"$ROOT/scripts/maintenance.sh" on "restore" --wait-closed || warn "could not close it
       cleanly; stopping the Server anyway."

log "stopping server and client"
compose stop server client

log "restoring"
# `--clean --if-exists`: drop what is there first, and do not complain about
# what is not. `--no-owner` because the roles inside a dump taken on another host
# need not exist here, and the stack has one role anyway.
#
# **Not `--exit-on-error`.** A restore reports harmless noise — an extension the
# role may not drop, a comment on something it does not own — and stopping on the
# first one leaves a half-restored database, which is strictly worse than a
# complete one with warnings. The count is reported below instead.
#
# **No filename and no `MSYS_NO_PATHCONV`, and both halves were paid for.**
# `pg_restore` reads standard input when given no file, which is the form that
# survives `docker compose exec -T`. The first version named `/dev/stdin` and set
# `MSYS_NO_PATHCONV=1` to stop Git Bash rewriting it — which also stopped
# `--project-directory` being converted, so Compose could not find `compose.yaml`
# and failed with *no configuration file provided*. That went into the log as one
# line, was reported as a pg_restore warning, and the restore **silently did
# nothing at all** while every check afterwards passed on data that had simply
# never been touched. Found 2026-08-30 by changing something first and watching
# the change survive.
# **Taken before, because afterwards there is nothing to compare against.**
# `--clean --if-exists` drops each relation and creates it again, so every table
# that was really restored comes back with a **new identity**. A restore that did
# nothing leaves the old ones exactly where they were, and that is the only
# difference visible from outside.
schema_before=$(psql_scalar "SELECT coalesce(sum(c.oid::bigint), 0) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind = 'r'" | tr -d '[:space:]')

if ! compose exec -T postgres pg_restore \
        --clean --if-exists --no-owner --no-privileges \
        -U "$(setting POSTGRES_USER algojudge)" \
        -d "$(setting POSTGRES_DB algojudge)" <"$dump" 2>"$ROOT/state/restore.log"; then
    warn "pg_restore reported errors — $(wc -l <"$ROOT/state/restore.log") line(s) in state/restore.log.
       Read them before trusting this installation: some are routine, and one of
       them being 'relation does not exist' on a table you care about is not."
fi

# **A restore that restored nothing must not report success**, and counting
# tables cannot tell. The Server creates the whole schema at start, so every
# table is already there before a restore begins — the count this used to check
# passes on exactly the silent no-op it was written to catch, which is the
# failure recorded above. What a real restore changes is the **identity** of
# every relation, because `--clean` drops and recreates them.
restored_tables=$(psql_scalar "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'" | tr -d '[:space:]')
if [ "${restored_tables:-0}" -lt 2 ]; then
    die "after restoring, the database holds ${restored_tables:-0} table(s). Nothing was
       restored. state/restore.log has why, and the installation is still closed."
fi

schema_after=$(psql_scalar "SELECT coalesce(sum(c.oid::bigint), 0) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind = 'r'" | tr -d '[:space:]')
if [ "${schema_after:-0}" = "${schema_before:-0}" ]; then
    die "every table in this database is the same one it was before the restore ran,
       so nothing was replaced. state/restore.log has why, and the installation is
       still closed. This is the check a table count could not make."
fi

log "starting server and client"
compose up -d server client

if wait_healthy 180; then
    log "healthy."
else
    die "the stack did not come back healthy within 180s. \`docker compose logs server\`
       — if the schema moved, the migration is in there."
fi

"$ROOT/scripts/maintenance.sh" off

log "restored from $(basename "$dump"). Sign in and check something you recognise
       before telling anybody it worked."
