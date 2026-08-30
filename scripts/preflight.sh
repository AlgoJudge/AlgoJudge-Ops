#!/usr/bin/env bash
#
# Refuses now, with a sentence, rather than half way up with a stack trace.
#
#     ./scripts/preflight.sh
#
# **Every check here is something that fails later and worse.** An empty database
# password starts a database anybody can open; a missing admin token produces an
# installation nobody can sign in to and no way to find out why; a CIDR with host
# bits set stops the Server at startup with a message about a network nobody
# wrote; a relative `RUNNER_WORK_DIR` gives the daemon a path it cannot open, and
# the daemon answers that with an **empty directory** rather than an error, so
# every submission runs against nothing and no test fails visibly.
#
# It is also what `make up` runs first, so the ordinary path is checked whether
# or not anybody remembers this file exists.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

problems=0
report() { warn "$*"; problems=$((problems + 1)); }

[ -f "$ROOT/.env" ] || die "no .env — copy .env.example to .env and fill it in"
load_env

# ── The three with no default ───────────────────────────────────────────────

if [ -z "${AJ_ADMIN_TOKEN:-}" ]; then
    report "AJ_ADMIN_TOKEN is empty. /admin is closed while it is, and that includes
       the only way to set the administrator's password — so there would be no
       way into this installation at all. Generate one: openssl rand -base64 36"
elif [ "${#AJ_ADMIN_TOKEN}" -lt 24 ]; then
    report "AJ_ADMIN_TOKEN is ${#AJ_ADMIN_TOKEN} characters. It is a long-lived
       secret on a surface with no rate limit; use at least 24."
fi

if [ -z "${POSTGRES_PASSWORD:-}" ]; then
    report "POSTGRES_PASSWORD is empty, which starts a database whose password is
       the empty string. Generate one: openssl rand -base64 36"
fi

# ── The Runner's work directory ─────────────────────────────────────────────

case ",${COMPOSE_PROFILES:-}," in
    *,runner,*)
        if [ -z "${RUNNER_WORK_DIR:-}" ]; then
            report "RUNNER_WORK_DIR is empty and the 'runner' profile is active. It must
       be an absolute host path — see .env.example."
        elif [ "${RUNNER_WORK_DIR#/}" = "$RUNNER_WORK_DIR" ]; then
            # Not "does it exist": Compose creates it. The check is that it is
            # absolute, because the Runner hands this string to the Docker
            # daemon and a relative one resolves against the daemon's own idea
            # of the filesystem — which silently produces an empty directory.
            report "RUNNER_WORK_DIR is '$RUNNER_WORK_DIR', which is relative. The Docker
       daemon is given this path directly, and a path it cannot open becomes an
       empty directory rather than an error — so every submission would run
       against nothing. Write an absolute path."
        fi

        # **The group the socket actually has, not the one somebody guessed.**
        # The Runner image runs as `nonroot`, so it reaches the daemon only
        # through `group_add` — and a wrong number produces `Permission denied
        # (os error 13)` from deep inside an HTTP client, which names neither the
        # socket nor the group. Measured 2026-08-30: Docker Desktop's socket is
        # `root:root`, so DOCKER_GID=0 there, while a Linux host has `root:docker`
        # and it is that group's id.
        #
        # Asked of a container rather than of this host: on Docker Desktop and
        # under WSL the socket this shell can see is not the one the daemon
        # serves, and the host's `/etc/group` is not the container's.
        socket_gid=$(MSYS_NO_PATHCONV=1 docker run --rm \
            -v /var/run/docker.sock:/var/run/docker.sock alpine \
            stat -c '%g' /var/run/docker.sock 2>/dev/null | tr -d '[:space:]')

        if [ -z "$socket_gid" ]; then
            warn "could not read the group of /var/run/docker.sock. If the Runner logs
       'Permission denied (os error 13)', DOCKER_GID is the reason."
        elif [ "$socket_gid" != "$(setting DOCKER_GID 999)" ]; then
            report "DOCKER_GID is $(setting DOCKER_GID 999) and the daemon's socket is owned by group
       $socket_gid. The Runner runs unprivileged and reaches the daemon only
       through that group, so as written it will start, fail to open the socket,
       and restart for ever. Write DOCKER_GID=$socket_gid."
        fi
        ;;
esac

# ── Trusted proxies ─────────────────────────────────────────────────────────

networks=${TRUSTED_PROXY_NETWORKS:-}
if [ -z "$networks" ]; then
    report "TRUSTED_PROXY_NETWORKS is empty. The Server refuses to start without it:
       trusting every sender of X-Forwarded-For lets a visitor state their own
       address. Use 'none' if nothing sits in front of it."
elif [ "$networks" != "none" ]; then
    # **A CIDR with host bits set is refused by the Server, by name.** .NET 10
    # normalises `10.0.5.17/24` to `10.0.5.0/24` without a word, which turns a
    # typo meaning one machine into one meaning a laboratory — so the Server
    # compares what was written against the base address and stops. Catching it
    # here means the message arrives before the container does.
    IFS=',' read -ra entries <<<"$networks"
    for entry in "${entries[@]}"; do
        entry=$(printf '%s' "$entry" | tr -d '[:space:]')
        [ -n "$entry" ] || continue
        case "$entry" in
            */*) : ;;
            *) report "TRUSTED_PROXY_NETWORKS entry '$entry' has no prefix length. A bare
       address belongs in KnownProxies, not KnownNetworks."; continue ;;
        esac

        address=${entry%/*}
        bits=${entry#*/}
        case "$address" in
            *:*) continue ;;  # IPv6: left to the Server, which reports it properly.
        esac

        IFS='.' read -r a b c d <<<"$address"
        value=$(( (a << 24) + (b << 16) + (c << 8) + d ))
        # The host part is what a correct network address has all-zero.
        if [ "$bits" -lt 32 ] && [ $((value & ((1 << (32 - bits)) - 1))) -ne 0 ]; then
            masked=$((value & ~(((1 << (32 - bits)) - 1))))
            report "TRUSTED_PROXY_NETWORKS entry '$entry' has host bits set. The Server
       refuses it at startup. Write $((masked >> 24 & 255)).$((masked >> 16 & 255)).$((masked >> 8 & 255)).$((masked & 255))/$bits if that is what you meant."
        fi
    done

    # They are two variables and one fact. Disagreeing means the Server trusts a
    # network nginx is not on, which reads every visitor's address as the proxy's.
    if [ -n "${EDGE_SUBNET:-}" ] && [ "$networks" != "$EDGE_SUBNET" ] \
        && [[ ",$networks," != *",$EDGE_SUBNET,"* ]]; then
        warn "TRUSTED_PROXY_NETWORKS ($networks) does not include EDGE_SUBNET
       ($EDGE_SUBNET). With the bundled nginx that means every visitor's address
       is recorded as the proxy's. Deliberate behind somebody else's proxy."
    fi
fi

# ── TLS ─────────────────────────────────────────────────────────────────────

case ",${COMPOSE_PROFILES:-}," in
    *,edge,*)
        if [ ! -s "$ROOT/certs/fullchain.pem" ] || [ ! -s "$ROOT/certs/privkey.pem" ]; then
            warn "no certificate in certs/. Run ./scripts/render-tls.sh for a self-signed
       pair — every browser will say so, and the installation will work."
        fi
        ;;
esac

# ── The backup budget ───────────────────────────────────────────────────────
#
# **Written rather than demanded.** A count policy does not bound disk usage, and
# an operator should not have to work out a sensible ceiling before their first
# start. 25% of the filesystem, and never past 50%, so a backup directory cannot
# be the thing that fills the disk PostgreSQL is writing to.

backup_dir=$(setting BACKUP_DIR "./backups")
mkdir -p "$backup_dir"
if [ -z "${BACKUP_MAX_TOTAL_GB:-}" ]; then
    total_kb=$(df -Pk "$backup_dir" | awk 'NR == 2 { print $2 }')
    if [ -n "$total_kb" ]; then
        quarter=$((total_kb / 4 / 1024 / 1024))
        [ "$quarter" -lt 1 ] && quarter=1
        log "BACKUP_MAX_TOTAL_GB was empty; writing ${quarter} (25% of the filesystem)."
        # Replaced in place rather than appended: a second assignment further
        # down the file would silently win and the first would read as the value.
        if grep -q '^BACKUP_MAX_TOTAL_GB=' "$ROOT/.env"; then
            sed -i "s|^BACKUP_MAX_TOTAL_GB=.*|BACKUP_MAX_TOTAL_GB=$quarter|" "$ROOT/.env"
        else
            printf 'BACKUP_MAX_TOTAL_GB=%s\n' "$quarter" >>"$ROOT/.env"
        fi
    fi
fi

# ── Secrets where they should not be ────────────────────────────────────────

if git -C "$ROOT" ls-files --error-unmatch .env >/dev/null 2>&1; then
    report ".env is tracked by Git. A secret committed once stays committed —
       remove it from the index now, before it is pushed anywhere."
fi

perms=$(stat -c '%a' "$ROOT/.env" 2>/dev/null || echo unknown)
case "$perms" in
    600 | 400) : ;;
    unknown) : ;;  # Windows and some mounts do not report a usable mode.
    *) warn ".env is mode $perms. It holds every secret this installation has:
       chmod 600 .env" ;;
esac

# ── The verdict ─────────────────────────────────────────────────────────────

if [ "$problems" -gt 0 ]; then
    die "$problems problem(s) above. Nothing was started."
fi

log "ready: $(setting COMPOSE_PROFILES 'no profiles set') on $(setting TZ 'the host default zone')."
