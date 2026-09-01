#!/usr/bin/env bash
#
# Installs `cron/algojudge.cron`, after checking that the running cron honours
# the timezone it declares.
#
#     ./scripts/install-cron.sh
#     ./scripts/install-cron.sh --print     show what would be installed
#
# **A deliberate call, never automatic.** Nothing about bringing this stack up
# schedules anything; an installation that wants a nightly backup asks for one.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

load_env

CRON_FILE="$ROOT/cron/algojudge.cron"
[ -f "$CRON_FILE" ] || die "no $CRON_FILE"

zone=$(setting TZ "")
rendered=$(mktemp)
add_cleanup 'rm -f "$rendered"'

# The crontab ships with a path and a zone that are examples. Both are rewritten
# to what this installation actually is, so the file that gets installed is one
# nobody has to remember to edit.
sed -e "s|/opt/algojudge-ops|$ROOT|g" \
    ${zone:+-e "s|^CRON_TZ=.*|CRON_TZ=$zone|"} \
    "$CRON_FILE" >"$rendered"

if [ "${1-}" = "--print" ]; then
    cat "$rendered"
    exit 0
fi

command -v crontab >/dev/null 2>&1 || die "the crontab command is not installed. This host
       does not run cron; use whatever it does schedule with — the three commands
       are in cron/algojudge.cron and need nothing but a shell."

# ── Installing ──────────────────────────────────────────────────────────────
#
# **Merged, not replaced.** A crontab is shared with everything else on the host,
# and installing ours by overwriting it is how somebody loses a job they have had
# for six years. Our own lines are delimited so a second run replaces them
# instead of appending a duplicate.
#
# **The CRON_TZ check is done by installing, not by probing.** `crontab <file>`
# replaces the whole crontab, so a probe that writes a one-line file to see
# whether it is accepted would destroy everything else on the host in order to
# find out. Instead the real thing is offered, and if this cron refuses it — Vixie
# and cronie accept it, not every implementation does — the same content goes in
# again without the line, with a warning. Nothing is ever written that does not
# already contain everything that was there.

# **An unreadable crontab is not an empty one**, and the difference is the whole
# of this file's promise. `crontab -l 2>/dev/null || true` cannot tell "this user
# has none" from "this user may not have one" or "the spool could not be read":
# all three give a non-zero exit and a discarded message, `existing` comes out
# empty, and the merge below then writes a crontab holding nothing but ours —
# destroying every unrelated job on the host, silently, from a script whose own
# comment says that must not happen.
crontab_error=$(mktemp)
add_cleanup "rm -f '$crontab_error'"

crontab_status=0
current=$(crontab -l 2>"$crontab_error") || crontab_status=$?

# The one failure that means "there is nothing here yet". Vixie cron, cronie and
# busybox all say it in these words; anything else is refused rather than guessed.
if [ "$crontab_status" -ne 0 ] && ! grep -qi 'no crontab' "$crontab_error"; then
    die "could not read the crontab for $(id -un): $(tr '
' ' ' <"$crontab_error")
       Nothing was written. An unreadable crontab is not an empty one, and merging
       into one this script cannot see would replace whatever it holds."
fi

existing=$(printf '%s' "$current" | sed '/# >>> algojudge >>>/,/# <<< algojudge <<</d')

install_crontab() {
    {
        printf '%s\n' "$existing"
        cat <<'MARKER'
# >>> algojudge >>>
# Written by scripts/install-cron.sh. Edit cron/algojudge.cron and run it
# again rather than editing between these markers.
MARKER
        cat "$1"
        printf '# <<< algojudge <<<\n'
    } | crontab -
}

log "installing into the crontab for $(id -un)"

if ! install_crontab "$rendered" 2>/dev/null; then
    warn "this cron would not accept the crontab, most likely the CRON_TZ line. The
       schedule cannot then be anchored to ${zone:-the configured zone} and will run in the
       host's own. If those differ, the backup will not run when you think it
       does — check \`date\` on this host."
    sed -i '/^CRON_TZ=/d' "$rendered"
    install_crontab "$rendered" || die "cron refused the crontab even without CRON_TZ.
       Nothing was changed. The three commands are in cron/algojudge.cron and need
       nothing but a shell — schedule them with whatever this host does use."
else
    # Accepted is not the same as honoured: an implementation that ignores the
    # line accepts it silently. Said rather than checked, because there is no way
    # to check it without waiting until four in the morning.
    if [ -n "$zone" ] && crontab -l 2>/dev/null | grep -q "^CRON_TZ=$zone"; then
        log "CRON_TZ=$zone accepted. Vixie cron and cronie honour it; if this host
       runs something else, confirm once that the first backup lands at 04:00
       local rather than 04:00 UTC."
    fi
fi

mkdir -p /var/log/algojudge 2>/dev/null || warn "could not create /var/log/algojudge.
       The entries write there; create it, or edit the paths in the crontab."

log "installed. \`crontab -l\` to see it."
log "**The update entry is commented out**, deliberately. Uncomment it only once a
       restore has been rehearsed — an automatic update with an untested backup
       behind it is a nightly opportunity to lose an installation."
