#!/usr/bin/env bash
#
# Refuses now, with a sentence, rather than halfway up with a stack trace.
#
#     ./scripts/preflight.sh
#
# **Every check here is something that fails later and worse.** It is also what
# `make up` runs first, so the ordinary path is checked whether or not anybody
# remembers this file exists.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

problems=0
report() { warn "$*"; problems=$((problems + 1)); }

[ -f "$ROOT/.env" ] || die "no .env — copy .env.example to .env and fill it in"
load_env

# ── The two with no default ─────────────────────────────────────────────────

if [ -z "${AJ_ADMIN_TOKEN:-}" ]; then
    report "AJ_ADMIN_TOKEN is empty. /admin is closed while it is, and that includes
       the only way to set the administrator's password — so there would be no
       way into this installation at all. Generate one: openssl rand -base64 36"
elif [ "$AJ_ADMIN_TOKEN" = "admin-token-development-only" ]; then
    # Long enough to pass the length check below, which is why it is named
    # here. The Server closes `/admin` on this value, so it is no way in.
    report "AJ_ADMIN_TOKEN is the well-known development token that this product's
       development compose files carry. The Server closes /admin when it is set
       to that, so there is no way to set the administrator's password and
       scripts/maintenance.sh cannot open or close the installation — which
       stops backup.sh --quiesce, update.sh and restore.sh at that step.
       Generate one: openssl rand -base64 36"
elif [ "${#AJ_ADMIN_TOKEN}" -lt 24 ]; then
    report "AJ_ADMIN_TOKEN is ${#AJ_ADMIN_TOKEN} characters. It is a long-lived
       secret on a surface with no rate limit; use at least 24."
fi

if [ -z "${POSTGRES_PASSWORD:-}" ]; then
    report "POSTGRES_PASSWORD is empty, which starts a database whose password is
       the empty string. Generate one: openssl rand -base64 36"
fi

# ── Where the Runners keep their bytes ──────────────────────────────────────

# **The cache and the scratch are Docker volumes**, and each judged container
# mounts its subdirectory out of the cache as `subpath`.

if runs_service runner-1 runner; then
        # **API 1.45 is this stack's floor, not a recommendation.** `subpath`
        # arrived in Docker Engine 26 (April 2024) and in Podman 5; an older
        # daemon cannot express that mount and the Runner refuses to judge.
        api=$(docker version --format '{{.Server.APIVersion}}' 2>/dev/null | tr -d '[:space:]')
        if [ -n "$api" ] && [ "$(printf '%s\n1.45\n' "$api" | sort -V | head -n1)" != "1.45" ]; then
            report "this daemon speaks Docker API $api, and the Runners' cache volume needs
       1.45 (Engine 26, April 2024; Podman 5). The Runner would refuse to judge.
       Update the daemon."
        fi

        # **Lanes against processors, per Runner.** A Runner given fewer
        # processors than the tests it is told to judge at once refuses to
        # start, and `restart: unless-stopped` turns that into a loop. The
        # arithmetic is here rather than in the Runner's own words because the
        # value an operator has to change is in this file, and because two
        # Runners can disagree about it while sharing one setting.
        lanes=$(setting RUNNER_TESTS_AT_ONCE 1)

        # **An empty cpuset is every processor the host has**, which is what
        # ships, so there the floor is the host's count and the per-Runner
        # arithmetic below never sees it.
        host_processors=$(nproc 2>/dev/null || echo 0)
        case ",$(setting COMPOSE_PROFILES ''),"  in
            *,runner,*)
                if [ "$host_processors" -gt 0 ] && [ "$lanes" -gt "$host_processors" ]; then
                    report "RUNNER_TESTS_AT_ONCE is $lanes and this host has
       $host_processors processor(s). A Runner refuses to start when it cannot
       give every lane a processor of its own, and \`restart: unless-stopped\`
       turns that into a loop. Lower RUNNER_TESTS_AT_ONCE."
                fi
                ;;
        esac

        for n in 1 2; do
            eval "set_for_runner=\${RUNNER_${n}_CPUSET:-}"
            [ -n "$set_for_runner" ] || continue

            # **Every processor a cpuset names has to be on this host**, or
            # the daemon refuses the container and `up -d --wait` stops with
            # half the stack running. Skipped where sysfs publishes nothing.
            if [ -d /sys/devices/system/cpu/cpu0 ]; then
                absent=$(
                    for piece in $(echo "$set_for_runner" | tr ',' ' '); do
                        case "$piece" in
                            *-*) first=${piece%%-*}; last=${piece##*-}
                                 c=$first
                                 while [ "$c" -le "$last" ]; do
                                     echo "$c"; c=$((c + 1))
                                 done ;;
                            *)   echo "$piece" ;;
                        esac
                    done | while read -r cpu; do
                        [ -d "/sys/devices/system/cpu/cpu$cpu" ] || printf '%s ' "$cpu"
                    done
                )
                if [ -n "${absent:-}" ]; then
                    report "RUNNER_${n}_CPUSET names processor(s) this host does not have:
       ${absent}. The daemon refuses to create that container -- \`Requested
       CPUs are not available\` -- so \`docker compose up -d --wait\` stops with
       part of the stack running. Leave the cpuset empty to take every
       processor, or name only what \`lscpu -p=CPU,CORE\` lists."
                fi
            fi

            # `0-3,8` names five processors; count them the way the kernel
            # spells them rather than counting commas.
            processors=$(
                echo "$set_for_runner" | tr ',' '
' | while read -r piece; do
                    case "$piece" in
                        *-*) first=${piece%%-*}; last=${piece##*-}
                             echo $((last - first + 1)) ;;
                        '')  ;;
                        *)   echo 1 ;;
                    esac
                done | awk '{ total += $1 } END { print total + 0 }'
            )
            if [ "$processors" -lt "$lanes" ]; then
                report "RUNNER_${n}_CPUSET names $processors processor(s) and
       RUNNER_TESTS_AT_ONCE is $lanes. That Runner refuses to start: a lane
       without a processor of its own is two judged runs sharing one, which
       spends more processor time on the same work and a time limit is
       processor time. Widen the cpuset or lower RUNNER_TESTS_AT_ONCE."
            fi

            # **And lanes against cores, which is the number that decides what a
            # submission is charged.** A processor is the floor the Runner
            # refuses below; a core is what a lane actually wants, because a
            # lane holds the judged run, the judge reading it and the measuring
            # shim. A warning and not a problem, exactly as the Runner treats
            # it: the installation works either way, and a host may have no
            # siblings to give.
            cores=$(
                for piece in $(echo "$set_for_runner" | tr ',' ' '); do
                    case "$piece" in
                        *-*) first=${piece%%-*}; last=${piece##*-}
                             c=$first
                             while [ "$c" -le "$last" ]; do
                                 echo "$c"; c=$((c + 1))
                             done ;;
                        *)   echo "$piece" ;;
                    esac
                done | while read -r cpu; do
                    cat "/sys/devices/system/cpu/cpu$cpu/topology/thread_siblings_list" 2>/dev/null
                done | sort -u | grep -c .
            )
            # Unreadable topology -- a virtual machine that publishes none --
            # counts as nothing to say rather than as a complaint.
            if [ "${cores:-0}" -gt 0 ] && [ "$cores" -lt "$lanes" ]; then
                warn "RUNNER_${n}_CPUSET names $processors processor(s) on
       $cores core(s) and RUNNER_TESTS_AT_ONCE is $lanes, so a lane there holds
       one thread of a core rather than a core. Measured 2026-09-15 on one
       submission of 72 tests: 196 ms of processor time a test in lanes of a
       whole core against 318 ms in lanes of one thread, which put 610 of 864
       tests over a limit none of them reached at the wider setting -- and a
       time limit is processor time, so that is correct solutions refused. Per
       submission the two are the same speed. Set RUNNER_TESTS_AT_ONCE to
       $cores, or give this Runner both threads of every core it has:
       \`cat /sys/devices/system/cpu/cpu0/topology/thread_siblings_list\`."
            fi
        done

        # **A list of separators is not a list of problem types.** Since
        # 2026-09-04 the Runner refuses to start on one, and `restart:
        # unless-stopped` turns that into a loop nothing here would otherwise
        # explain — the value looks set, and every other check passes.
        #
        # An empty value is fine and deliberately not reported: `compose.yaml`
        # substitutes the default for it. What is refused is a value that is
        # present and names nothing, which is what a stray or trailing comma
        # produces.
        if [ -n "${RUNNER_PROBLEM_TYPES:-}" ]; then
            named=$(printf '%s' "$RUNNER_PROBLEM_TYPES" | tr ',' '
'                 | tr -d '[:space:]' | grep -c . || true)
            if [ "$named" -eq 0 ]; then
                report "RUNNER_PROBLEM_TYPES is '$RUNNER_PROBLEM_TYPES', which names no problem
       type. The Runner refuses to start on that, and an empty list would match
       no problem anyway. Leave it unset for the default."
            fi
        fi

        # **The group the socket actually has, not the one somebody guessed.**
        # The Runner image runs as `nonroot`, so it reaches the daemon only
        # through `group_add` — and a wrong number produces `Permission denied
        # (os error 13)` from deep inside an HTTP client, which names neither the
        # socket nor the group.
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
            # **A warning rather than a refusal.** The runner service is
            # `user: "0:0"` so that it can measure, and root opens the socket
            # whatever groups it is in, so a wrong value stops nothing -- but it
            # is still wrong, and it is what the service would need if it ever
            # ran unprivileged.
            warn "DOCKER_GID is $(setting DOCKER_GID 999) and the daemon's socket is owned by group
       $socket_gid. The Runner runs as root, so it reaches the socket anyway and
       nothing is broken by this. Write DOCKER_GID=$socket_gid."
        fi

        # **The cgroup version, which was never checked here at all.** The
        # Runner refuses v1 at start, so a stack on such a host comes up and the
        # Runner does not -- which reads as the Runner being broken rather than
        # as the host being wrong.
        version=$(docker info --format '{{.CgroupVersion}}' 2>/dev/null | tr -d '[:space:]')
        if [ -n "$version" ] && [ "$version" != "2" ]; then
            report "this host reports cgroup v$version, and the Runner requires v2. It will
       refuse to start: a time limit is decided on processor time read from
       cpu.stat, which is a v2 interface. The limits would be enforced on v1 --
       what cannot be done there is reach a verdict at all."
        fi

        # **The driver, and both of them are fine.** A cgroup parent is a path
        # under `cgroupfs` and a slice under `systemd`, and the Runner measures
        # under either -- so this refuses only a daemon that reports neither,
        # which means cgroups are switched off and nothing can be measured at
        # all. No installation has to reconfigure its daemon.
        driver=$(docker info --format '{{.CgroupDriver}}' 2>/dev/null | tr -d '[:space:]')
        case "$driver" in
            "" | cgroupfs | systemd) ;;
            *)
                report "the daemon's cgroup driver is '$driver', and the Runner knows cgroupfs
       and systemd. A time limit is decided on processor time read from a cgroup,
       so with neither there is nothing to read it from and the Runner will
       refuse to start rather than judge without it."
                ;;
        esac
fi

# ── The external Runner's account ───────────────────────────────────────────
#
# **Refused here rather than by the container.** The two values are `:-` in
# `compose.yaml` because Compose interpolates that file before it applies
# profiles, so a required marker there would break the four arrangements that
# never run this service. Empty therefore reaches the container, which exits
# while reading its configuration -- and behind `restart: unless-stopped` that is
# a crash loop, in an image with no shell to look into and no health check to go
# red.

if runs_service external-runner external-runner; then
        if [ -z "${EXTERNAL_JUDGE_USERNAME:-}" ] || [ -z "${EXTERNAL_JUDGE_PASSWORD:-}" ]; then
            report "this installation starts the External Runner and the judging system's
       account is not filled in. It signs in to $(setting EXTERNAL_JUDGE uva) under that account and
       refuses to start without it, over and over. Fill both in, or stop starting
       that service."
        fi

        log "this installation starts the External Runner. Two things this script cannot
       check decide whether it is ever handed work: external judging must be on
       for this installation, and an administrator must approve the Runner in the
       panel. Until both, its queue is empty and it looks perfectly healthy."
fi

# ── Trusted proxies ─────────────────────────────────────────────────────────

networks=${TRUSTED_PROXY_NETWORKS:-}
proxies=${TRUSTED_PROXY_PROXIES:-}

# **`none` is a value for the proxies, not for the networks.** The Server
# switches the middleware off on `Forwarded:KnownProxies=none`; in
# `KnownNetworks` the same word is read as a CIDR block and refused at startup.
if [ "$networks" = none ]; then
    report "TRUSTED_PROXY_NETWORKS is 'none', which is not a network. The Server
       refuses it at startup. To run with nothing in front of this Server, write
       TRUSTED_PROXY_PROXIES=none and leave TRUSTED_PROXY_NETWORKS empty."
elif [ "$proxies" = none ] && [ -n "$networks" ]; then
    report "TRUSTED_PROXY_PROXIES is 'none' and TRUSTED_PROXY_NETWORKS is
       '$networks'. The Server takes 'none' only when it is the whole of what it
       has been told to trust, so it would read that network instead and keep the
       forwarded headers on. Empty TRUSTED_PROXY_NETWORKS, or drop the 'none'."
elif [ -z "$networks" ] && [ -z "$proxies" ]; then
    report "TRUSTED_PROXY_NETWORKS and TRUSTED_PROXY_PROXIES are both empty. The
       Server refuses to start: trusting every sender of X-Forwarded-For lets a
       visitor state their own address. Name the network your proxy reaches this
       Server from, or write TRUSTED_PROXY_PROXIES=none if nothing does."
elif [ -n "$networks" ]; then
    # **A CIDR with host bits set is refused by the Server, by name.** .NET 10
    # normalizes `10.0.5.17/24` to `10.0.5.0/24` without a word, which turns a
    # typo meaning one machine into one meaning a laboratory — so the Server
    # compares what was written against the base address and stops.
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

# ── Storage ─────────────────────────────────────────────────────────────────
#
# **The Server refuses at startup when the kind it was given has no path or no
# bucket**, and it refuses well -- by name.

case "$(setting STORAGE_KIND postgres)" in
    postgres) : ;;
    filesystem)
        [ -n "${STORAGE_PATH:-}" ] || report "STORAGE_KIND is filesystem and STORAGE_PATH is empty. The
       Server will not start without it."
        ;;
    s3)
        for name in STORAGE_ENDPOINT STORAGE_BUCKET STORAGE_ACCESS_KEY STORAGE_SECRET_KEY; do
            [ -n "${!name:-}" ] || report "STORAGE_KIND is s3 and $name is empty. All four are
       required together, and the Server will not start without them."
        done
        ;;
    *)
        report "STORAGE_KIND is '$(setting STORAGE_KIND postgres)', which is none of postgres,
       filesystem or s3. The Server refuses an unknown store kind at startup."
        ;;
esac

# **A dump is no longer the whole backup once files live outside the database.**
case "$(setting STORAGE_KIND postgres)" in
    filesystem | s3)
        log "STORAGE_KIND is $(setting STORAGE_KIND postgres): uploaded files are stored outside
       the database, so a pg_dump alone no longer restores this installation.
       Back the store up in step with it -- docs/OPERATIONS.md."
        ;;
esac

# ── TLS ─────────────────────────────────────────────────────────────────────

if runs_service nginx edge; then
        if [ ! -s "$ROOT/certs/fullchain.pem" ] || [ ! -s "$ROOT/certs/privkey.pem" ]; then
            warn "no certificate in certs/. Run ./scripts/render-tls.sh for a self-signed
       pair — every browser will say so, and the installation will work."
        fi
fi

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
