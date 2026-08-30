#!/usr/bin/env bash
#
# A self-signed certificate for `certs/`, so a first start produces a working
# instance instead of an nginx that will not start.
#
#     ./scripts/render-tls.sh
#     ./scripts/render-tls.sh algojudge.example.org
#
# **Development and first-boot only — every browser will say so.** This exists
# because the alternative is worse: with no certificate at all nginx exits with a
# message about a file, and somebody following the installation instructions gets
# a stack that will not come up and nothing to connect that to.
#
# **It refuses to overwrite.** A real certificate sitting here must survive
# somebody running this by mistake, and there is no undo for a private key.
#
# Renewal is the administrator's own — whatever they already use. Both port 80
# and port 443 serve `/.well-known/acme-challenge/` from `certs/acme/`, so an
# HTTP-01 challenge is never redirected away; after a renewal, reload with
#
#     docker compose exec nginx nginx -s reload
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

command -v openssl >/dev/null 2>&1 || die "the openssl command is not installed."

CERTS="$ROOT/certs"
mkdir -p "$CERTS" "$CERTS/acme"

# **Both files, not either.** Checking only one meant a failed run — which
# writes the key before it writes the certificate — left something that made the
# next run say "a certificate is already there" and exit 0. Found on 2026-08-30
# by the failure below, and the false success was the worse half of it.
if [ -s "$CERTS/fullchain.pem" ] && [ -s "$CERTS/privkey.pem" ]; then
    log "a certificate is already there, keeping it. Delete both files by hand if
       you really mean to replace it."
    exit 0
fi

if [ -e "$CERTS/privkey.pem" ] || [ -e "$CERTS/fullchain.pem" ]; then
    warn "one of the two files is there without the other — an earlier run failed
       half way. Removing both and starting again."
    rm -f "$CERTS/privkey.pem" "$CERTS/fullchain.pem"
fi

domain=${1:-localhost}

# **`subjectAltName`, not just a common name.** Every browser released this
# decade ignores CN for host matching, so a certificate with only a CN fails to
# match anything and the warning it produces says nothing useful about why.
#
# **The subject needs a second slash under Git Bash, and only there.** MSYS
# rewrites an argument beginning with `/` into a Windows path, so
# `-subj "/CN=localhost"` reaches openssl as `C:/Program Files/Git/CN=localhost`
# and it refuses: *this name is not in that format*. A leading `//` is the
# documented escape — MSYS strips one slash and openssl sees what was meant.
# Measured on 2026-08-30; the resulting certificate's subject is `CN = localhost`
# either way.
#
# `MSYS_NO_PATHCONV=1` is **not** the fix here, though it is elsewhere in this
# repository: it would also stop the two output paths being converted, and
# openssl is a Windows binary that cannot open `/c/Users/...`.
subject="/CN=$domain"
case "${OSTYPE:-}" in
    msys* | cygwin*) subject="/$subject" ;;
esac

# **Nothing is sent to /dev/null.** This call used to end `2>/dev/null`, which is
# exactly how the failure above went unnoticed — openssl said precisely what was
# wrong and the script threw it away, then reported success on the next run.
if ! openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$CERTS/privkey.pem" \
    -out "$CERTS/fullchain.pem" \
    -days 365 \
    -subj "$subject" \
    -addext "subjectAltName=DNS:$domain,DNS:localhost,IP:127.0.0.1"; then
    rm -f "$CERTS/privkey.pem" "$CERTS/fullchain.pem"
    die "openssl failed; its message is above. Nothing was left behind."
fi

# A certificate that is not a pair is not a certificate, and the check above is
# only as good as this one.
[ -s "$CERTS/fullchain.pem" ] && [ -s "$CERTS/privkey.pem" ] \
    || die "openssl exited 0 but did not write both files."

chmod 600 "$CERTS/privkey.pem" 2>/dev/null || true

log "wrote a self-signed certificate for '$domain', valid 365 days."
log "**development only** — self-signed, and every browser will say so. Replace
       both files with a real pair before anybody but you uses this."
