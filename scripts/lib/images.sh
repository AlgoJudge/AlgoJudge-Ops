#!/usr/bin/env bash
#
# The four language images, in one place.
#
# **They are not services**, and that is the whole reason this file exists.
# `compose.yaml` hands them to the Runner as `AJ_Sandbox__Image__*` values, so
# everything built on `docker compose` is blind to them: `compose pull` does not
# fetch them, `compose config --images` does not list them, and `compose ps`
# will never show one. Anything this stack wants done to them has to be written
# out by hand, which is exactly how they came to be forgotten on first install.
#
# Sourced by `pull.sh`, `update.sh` and `rollback.sh` so that the four
# references have **one spelling**. `check-repository.py` compares it against
# `compose.yaml`, because a second spelling that drifts is a Runner pulling one
# image and judging in another.

LANGS="gcc clang python pypy"

# The reference, exactly as `compose.yaml` builds it for the Runner.
lang_image() { printf '%s/lang-%s:%s\n' "${REGISTRY:-ghcr.io/algojudge}" "$1" "${RUNNER_TAG:-0}"; }

# The `AJ_Sandbox__Image__*` suffix each one is handed to the Runner under.
lang_key() {
    case $1 in
        gcc) printf 'Gcc' ;; clang) printf 'Clang' ;;
        python) printf 'Python' ;; pypy) printf 'Pypy' ;;
    esac
}

# **Whether this host judges anything**, which decides whether the toolchain is
# worth several gigabytes to it. An application host with the Runners elsewhere
# wants none of them.
judges_here() { compose config --services 2>/dev/null | grep -qE '^runner-[0-9]+$'; }

# Fetches the four, saying so. **A failure is a warning and not a stop**: a host
# that already has a copy judges perfectly well with it, and this is also the
# air-gapped installation and the private registry an anonymous pull cannot
# authenticate to. A host with no copy at all is caught by the Runner, which
# refuses to register rather than claiming work it would fail.
pull_langs() {
    local lang image
    for lang in $LANGS; do
        image=$(lang_image "$lang")
        log "pulling $image"
        docker pull --quiet "$image" >/dev/null || warn "could not pull $image;
       a host that already has a copy keeps judging with it, and one that has
       none will be refused by the Runner at start with a sentence naming
       AJ_Sandbox__Image__$(lang_key "$lang")"
    done
}
