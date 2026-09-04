#!/usr/bin/env bash
#
# One dump, verified, and a directory that cannot grow without bound.
#
#     ./scripts/backup.sh
#     ./scripts/backup.sh --quiesce            take it with the Server closed
#     ./scripts/backup.sh --keep end-of-term --until 2027-03-01
#
# **`pg_dump` does not need the Server stopped.** It produces a transactionally
# consistent dump from a running database, so the nightly run costs no outage
# and `--quiesce` is off by default. What `--quiesce` buys is a dump with no
# evaluation in flight, which matters before a migration or a restore rehearsal.
#
# **What it does not cover is files that are not in the database.** With
# `STORAGE_KIND=postgres` — the default — the dump is the whole of the
# installation's state. With `filesystem` or `s3` it is not, and this script says
# so rather than producing something that restores to a broken installation.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

load_env
lock

# **Every file this script writes is 0600, and the directories 0700.**
# A dump carries every account, every password hash and the data-protection key
# ring that mints this installation's session cookies; `docs/OPERATIONS.md` says
# what a leaked one is worth. Under cron the shell's umask is 022, which would
# leave all of that world-readable on the host.
umask 077

BACKUP_DIR=$(backup_dir)
KEEP_DIR="$BACKUP_DIR/keep"
mkdir -p "$BACKUP_DIR" "$KEEP_DIR"
# `umask` only bounds what is created; a directory that already exists keeps the
# mode it was made with.
chmod 700 "$BACKUP_DIR" "$KEEP_DIR" 2>/dev/null || true

quiesce=false
pre_update=false
keep_label=""
keep_until=""

while [ $# -gt 0 ]; do
    case "$1" in
        --quiesce) quiesce=true ;;
        --pre-update) pre_update=true; quiesce=true ;;
        --keep) keep_label=${2:?--keep needs a label}; shift ;;
        --until) keep_until=${2:?--until needs a date}; shift ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done

# **`--until` is not optional, and it is a review date rather than a deletion
# date.** Nothing in `keep/` is ever removed automatically — deleting a copy
# somebody deliberately preserved is not a decision a cron job may take — so what
# stops named holds quietly reintroducing unbounded history is that every overdue
# one is reported on every run. Without a date there is nothing to report.
if [ -n "$keep_label" ]; then
    [ -n "$keep_until" ] || die "--keep needs --until <date>. It is a review date, not a
       deletion date: nothing in keep/ is deleted for you, so the only thing that
       stops an archive nobody revisits is being asked about it."
    date -d "$keep_until" >/dev/null 2>&1 || die "--until '$keep_until' is not a date this
       system understands. Write it as YYYY-MM-DD."
fi

# ── The preset ──────────────────────────────────────────────────────────────

case "$(setting BACKUP_PRESET standard)" in
    minimal)  preset_daily=3;  preset_weekly=2; preset_monthly=0 ;;
    standard) preset_daily=7;  preset_weekly=4; preset_monthly=2 ;;
    extended) preset_daily=14; preset_weekly=8; preset_monthly=3 ;;
    *) die "BACKUP_PRESET must be minimal, standard or extended" ;;
esac

KEEP_DAILY=$(setting BACKUP_KEEP_DAILY "$preset_daily")
KEEP_WEEKLY=$(setting BACKUP_KEEP_WEEKLY "$preset_weekly")
KEEP_MONTHLY=$(setting BACKUP_KEEP_MONTHLY "$preset_monthly")
MIN_KEEP=$(setting BACKUP_MIN_KEEP 2)
MAX_TOTAL_GB=$(setting BACKUP_MAX_TOTAL_GB 0)
RESERVE_GB=$(setting BACKUP_FREE_SPACE_RESERVE_GB 10)

# ── What this backup does and does not cover ────────────────────────────────

storage_kind=$(setting STORAGE_KIND postgres)
case "$storage_kind" in
    postgres)
        coverage="complete: files are in the database"
        ;;
    filesystem)
        # Restoring the dump alone gives an installation that answers 503 on
        # every download with nothing naming the cause.
        coverage="INCOMPLETE: STORAGE_KIND=filesystem, so uploaded files are NOT in this dump"
        warn "STORAGE_KIND is 'filesystem'. This dump does not contain the uploaded
       files, and restoring it alone gives an installation whose rows point at
       bytes that are not there. Back up the store's volume in the same window,
       or move the files into the database with \`aj-admin storage migrate\`."
        ;;
    s3)
        coverage="INCOMPLETE: STORAGE_KIND=s3, so uploaded files are NOT in this dump"
        warn "STORAGE_KIND is 's3'. This dump does not contain the uploaded files.
       Their bucket needs its own backup, with versioning or a lifecycle rule —
       this script cannot and should not reach into somebody's object store."
        ;;
    *) die "STORAGE_KIND is '$storage_kind', which is not postgres, filesystem or s3" ;;
esac

# ── Room to work ────────────────────────────────────────────────────────────

have_server || die "no stack here to back up"

previous=$(find "$BACKUP_DIR" -maxdepth 1 -name 'algojudge-*.dump' -printf '%s\n' 2>/dev/null | sort -n | tail -1)
if [ -n "$previous" ]; then
    estimate=$((previous * 12 / 10))     # the last one, and a fifth again
else
    # **The first run has nothing to go on**, so it uses the database's own size
    # as an upper bound. A compressed dump is far smaller; refusing on the
    # uncompressed figure is the safe direction to be wrong in.
    estimate=$(psql_scalar "SELECT pg_database_size(current_database())" | tr -d '[:space:]')
    estimate=${estimate:-1073741824}
fi

free_kb=$(df -Pk "$BACKUP_DIR" | awk 'NR == 2 { print $4 }')
needed_kb=$(( estimate / 1024 + RESERVE_GB * 1024 * 1024 ))
if [ "$free_kb" -lt "$needed_kb" ]; then
    die "not enough room: $(human_bytes $((free_kb * 1024))) free, and this needs about
       $(human_bytes "$estimate") plus a ${RESERVE_GB} GB reserve. Nothing was
       deleted and no dump was made — see 'when even the floor does not fit' in
       docs/OPERATIONS.md."
fi

# ── The dump ────────────────────────────────────────────────────────────────

stamp=$(date '+%Y%m%d-%H%M%S')
if [ -n "$keep_label" ]; then
    target="$KEEP_DIR/algojudge-$(date '+%Y-%m-%d')-$keep_label.dump"
else
    target="$BACKUP_DIR/algojudge-$stamp.dump"
fi

closed=false
if $quiesce; then
    log "closing the installation first"
    "$ROOT/scripts/maintenance.sh" on "${pre_update:+update: }backup" --wait-closed
    closed=true
fi

reopen() {
    if $closed; then
        "$ROOT/scripts/maintenance.sh" off || warn "could not reopen — do it by hand:
       docker compose exec -T server aj-admin maintenance off"
        closed=false
    fi
}
# **Reopened on every exit path, including a failure and a Ctrl+C.** An
# installation left closed because a backup died is an outage nobody chose.
# Registered rather than trapped: `lib/common.sh` owns the single EXIT trap, and
# a second one here would silently replace the release of the lock.
add_cleanup reopen

log "dumping to $(basename "$target")"

# `-Fc`: custom format, compressed, and the only one `pg_restore` can restore
# selectively from. Written to a `.partial` first so a run killed half way
# never leaves something that looks like a backup.
if ! compose exec -T postgres pg_dump -Fc \
        -U "$(setting POSTGRES_USER algojudge)" \
        -d "$(setting POSTGRES_DB algojudge)" >"$target.partial"; then
    rm -f "$target.partial"
    die "pg_dump failed. Nothing was written and nothing was rotated."
fi

# ── Verified before it is named ─────────────────────────────────────────────
#
# **Two checks, because the cheap one does not prove what it looks like it
# proves.** A custom-format archive keeps its table of contents at the *front*,
# so `pg_restore --list` succeeds on a file that was truncated half way through
# the data — it reads the header and stops. It still catches an empty file, a
# write that failed on the first block, and anything that is not a PostgreSQL
# archive at all.
#
# What proves the data is there is reading every block, which is what
# `pg_restore -f /dev/null` does. That costs a full decompression pass, so it is
# opt-in rather than something a nightly run blocks on.
#
# Both run inside the container: the host is not required to have PostgreSQL
# installed at all, and this stack ships it.
#
# **No filename, not `/dev/stdin`.** `pg_restore` reads standard input when it is
# given no file, and that is the form that works through `docker compose exec -T`
# — naming `/dev/stdin` explicitly fails with *did not find magic string in file
# header* on a dump that is perfectly good.

if ! compose exec -T postgres pg_restore --list <"$target.partial" >/dev/null 2>&1; then
    rm -f "$target.partial"
    die "the dump did not verify — pg_restore could not read it as an archive.
       It has been deleted rather than kept as a backup that is not one."
fi

if [ "$(setting BACKUP_VERIFY_FULL false)" = "true" ]; then
    log "reading the whole archive back"
    if ! compose exec -T postgres pg_restore -f /dev/null <"$target.partial" >/dev/null 2>&1; then
        rm -f "$target.partial"
        die "the dump listed but did not read back in full — it is truncated or
       corrupt past its table of contents. Deleted."
    fi
fi

mv "$target.partial" "$target"
size=$(stat -c '%s' "$target")
log "wrote $(human_bytes "$size")"

# ── The .meta beside it ─────────────────────────────────────────────────────
#
# **What a restore needs to know before it starts.** Chiefly the schema: putting
# an old dump under a newer Server produces an installation that migrates
# forward on its next start, which is fine when it is expected and a surprise
# otherwise. `restore.sh` reads this file and says so.

{
    printf 'taken=%s\n' "$(date -Iseconds)"
    printf 'taken_utc=%s\n' "$(date -u -Iseconds)"
    printf 'size=%s\n' "$size"
    printf 'sha256=%s\n' "$(sha256sum "$target" | cut -d' ' -f1)"
    printf 'storage_kind=%s\n' "$storage_kind"
    printf 'coverage=%s\n' "$coverage"
    printf 'quiesced=%s\n' "$quiesce"
    printf 'server_tag=%s\n' "$(setting SERVER_TAG 0)"
    printf 'server_image=%s\n' "$(compose images -q server 2>/dev/null | head -1)"
    printf 'postgres_tag=%s\n' "$(setting POSTGRES_TAG 18)"
    printf 'schema=%s\n' "$(psql_scalar "SELECT string_agg(\"MigrationId\", ',' ORDER BY \"MigrationId\") FROM \"__EFMigrationsHistory\"" | tr -d '[:space:]')"
    printf 'schema_lti=%s\n' "$(psql_scalar "SELECT string_agg(\"MigrationId\", ',' ORDER BY \"MigrationId\") FROM \"__EFMigrationsHistory_Lti\"" | tr -d '[:space:]')"
    [ -n "$keep_label" ] && printf 'hold=%s\nreview=%s\n' "$keep_label" "$keep_until"
} >"$target.meta"

reopen

# **Rotation does not apply to a named hold**, so the run ends here.
if [ -n "$keep_label" ]; then
    log "held as '$keep_label', for review on $keep_until. Nothing in keep/ is ever
       deleted automatically; the next ordinary run reminds you once that date
       passes."
    exit 0
fi

# ── Rotation ────────────────────────────────────────────────────────────────
#
# **Two bounds, and neither alone is enough.** The count policy answers "how far
# back can I go"; the size budget answers "how much disk will this cost". A
# backup directory that fills the disk stops PostgreSQL writing, which turns a
# safety mechanism into the outage it was meant to protect against.
#
# The three counts are a **union of sets, not a sum**: one file can be the newest
# of its day, of its ISO week and of its month at once, and is then stored once.
# A file no rule claims is deleted.
#
# **"Days on which a dump exists", not "the last N calendar days."** A host
# switched off for a fortnight would, under the calendar reading, come back
# holding no daily history at all.

survivors=$(mktemp)
add_cleanup 'rm -f "$survivors" "$survivors.all"'

# Newest first, so the first file seen in each period is the one kept.
find "$BACKUP_DIR" -maxdepth 1 -name 'algojudge-*.dump' -printf '%T@ %p\n' \
    | sort -rn | cut -d' ' -f2- >"$survivors.all"

keep_newest_per() {
    local format=$1 limit=$2
    [ "$limit" -gt 0 ] || return 0
    local seen="" period count=0
    while IFS= read -r file; do
        period=$(date -r "$file" "+$format")
        case " $seen " in *" $period "*) continue ;; esac
        seen="$seen $period"
        count=$((count + 1))
        [ "$count" -gt "$limit" ] && break
        printf '%s\n' "$file"
    done <"$survivors.all"
}

{
    keep_newest_per '%Y-%m-%d' "$KEEP_DAILY"
    keep_newest_per '%G-W%V' "$KEEP_WEEKLY"     # ISO week, matching ISO year
    keep_newest_per '%Y-%m' "$KEEP_MONTHLY"
} | sort -u >"$survivors"

removed=0
while IFS= read -r file; do
    if ! grep -qxF "$file" "$survivors"; then
        rm -f "$file" "$file.meta"
        removed=$((removed + 1))
    fi
done <"$survivors.all"
[ "$removed" -gt 0 ] && log "rotation removed $removed dump(s) no rule claimed"

# ── The size bound ──────────────────────────────────────────────────────────

if [ "$MAX_TOTAL_GB" -gt 0 ]; then
    budget=$((MAX_TOTAL_GB * 1024 * 1024 * 1024))

    # **`keep/` counts towards the budget.** Leaving it out would let an archive
    # nobody looks at fill the disk as reliably as an unbounded rotation would.
    used() { du -sb "$BACKUP_DIR" 2>/dev/null | cut -f1; }

    while [ "$(used)" -gt "$budget" ]; do
        remaining=$(find "$BACKUP_DIR" -maxdepth 1 -name 'algojudge-*.dump' | wc -l)
        if [ "$remaining" -le "$MIN_KEEP" ]; then
            warn "over the ${MAX_TOTAL_GB} GB budget with only $remaining dump(s) left.
       The floor of $MIN_KEEP is not crossed to make room — raise
       BACKUP_MAX_TOTAL_GB, or give BACKUP_DIR a filesystem of its own."
            break
        fi
        oldest=$(find "$BACKUP_DIR" -maxdepth 1 -name 'algojudge-*.dump' -printf '%T@ %p\n' \
            | sort -n | head -1 | cut -d' ' -f2-)
        [ -n "$oldest" ] || break
        log "over budget; dropping $(basename "$oldest")"
        rm -f "$oldest" "$oldest.meta"
    done

    held=$(du -sb "$KEEP_DIR" 2>/dev/null | cut -f1)
    if [ "${held:-0}" -gt $((budget / 2)) ]; then
        warn "keep/ is $(human_bytes "$held"), over half the ${MAX_TOTAL_GB} GB budget.
       Nothing in it is ever deleted automatically. Review the holds below."
    fi
fi

# ── Overdue holds ───────────────────────────────────────────────────────────
#
# **Every overdue hold is reported on every run.** A rotation reaching two
# months means nothing if an unreviewed hold from three years ago sits beside
# it, and personal data in a dump does not stop being personal data because
# somebody labelled the file.

today=$(date '+%s')
while IFS= read -r meta; do
    review=$(grep -m1 '^review=' "$meta" 2>/dev/null | cut -d= -f2)
    [ -n "$review" ] || continue
    if [ "$(date -d "$review" '+%s' 2>/dev/null || echo "$today")" -lt "$today" ]; then
        warn "hold '$(grep -m1 '^hold=' "$meta" | cut -d= -f2)' was due for review on
       $review: $(basename "${meta%.meta}"). Keep it deliberately, or delete it —
       nothing here will."
    fi
done < <(find "$KEEP_DIR" -maxdepth 1 -name '*.meta' 2>/dev/null)

total=$(find "$BACKUP_DIR" -maxdepth 1 -name 'algojudge-*.dump' | wc -l)
log "done: $total dump(s) in rotation, $(find "$KEEP_DIR" -maxdepth 1 -name '*.dump' 2>/dev/null | wc -l) held, $(human_bytes "$(du -sb "$BACKUP_DIR" | cut -f1)") total."
