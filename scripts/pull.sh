#!/usr/bin/env bash
#
# Fetches every image this installation runs, before anything needs one.
#
#     ./scripts/pull.sh
#
# **It exists because `docker compose pull` is not the whole of it.** The four
# language images are values the Runner is handed rather than services, so
# Compose cannot see them — and an installation that was installed and never
# updated therefore had no toolchain at all and failed every submission. That
# was the 0.1.0 report, and `make up` runs this now.
#
# **This is also where the multi-gigabyte download belongs.** In an operator's
# own terminal, with Docker's progress, at a moment they chose — rather than
# inside a Runner that a stack is waiting on, where the same minutes read as a
# hang.
#
# Nothing here is required for correctness: a Runner refuses to register
# without its images and says which setting to change. This is the friendlier
# line of defence, not the mechanism.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib/images.sh"

load_env
lock

log "pulling the service images"
compose pull --quiet || die "could not pull the service images. Check REGISTRY and
       this host's route to it; nothing has been changed."

if judges_here; then
    log "pulling the language images, which Compose cannot see"
    pull_langs
else
    log "no Runner in this installation's profiles, so the language images are not wanted here"
fi

log "every image this installation runs is on this host"
