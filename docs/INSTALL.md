# Installing AlgoJudge

From an empty directory to an installation that judges a submission.

> **Set `AJ_ADMIN_TOKEN` before the first `up`.** While it is empty
> `/api/v1/admin/**` is closed, and that includes the endpoint that sets the
> administrator's password. The seeded `admin` account's password is twenty
> random characters that are never logged, printed or stored anywhere readable —
> so an installation started without this token has no administrator anybody can
> sign in as, and the fix is to drop the database and start again.

## What the host needs

- **Docker with Compose v2 or later**, and cgroup **v2**. The Runner refuses to
  start on v1 unless deliberately overridden, and CI asserts v2 rather than
  trusting the flag.
- **`bash`, `openssl`, `find`, `du`, `df`** — the scripts use nothing else.
- **Disk for backups**, ideally on a **different filesystem** from the
  PostgreSQL volume. On one filesystem no reserve setting can guarantee that a
  backup will not starve the database it is backing up.
- **A bounded container log driver.** The default is an unbounded JSON file and
  it is the commonest way one of these hosts fills its disk:

  ```json
  { "log-driver": "json-file", "log-opts": { "max-size": "50m", "max-file": "5" } }
  ```

  in `/etc/docker/daemon.json`, then restart the daemon.

## One time, by hand: the packages must be public

The release workflow publishes to `ghcr.io/algojudge`, and **a package created
by its first push is private**. Until each is set to Public once, `docker pull`
needs a token, which defeats the point of not having a registry login in these
instructions.

There are **seven**: `algojudge-server`, `algojudge-client`, `algojudge-runner`,
`lang-gcc`, `lang-clang`, `lang-python`, `lang-pypy`. The workflow cannot do it;
somebody with access to the organisation's packages must.

> **Not done yet.** No release has been cut, so none of the seven exists. Until
> then this stack runs only against images built from the product repositories
> and tagged locally — see `docs/OPERATIONS.md`.

## 1. Clone and configure

```bash
git clone https://github.com/AlgoJudge/AlgoJudge-Ops.git /opt/algojudge-ops
cd /opt/algojudge-ops
cp .env.example .env
chmod 600 .env
```

**Three values have no default** and the stack will not start without them.
`.env.example` explains each where it sits; in short:

```ini
AJ_ADMIN_TOKEN=          # openssl rand -base64 36
POSTGRES_PASSWORD=       # openssl rand -base64 36, a different one
RUNNER_WORK_DIR=         # an ABSOLUTE host path, e.g. /srv/algojudge/runner-work
```

`RUNNER_WORK_DIR` must be absolute because the Runner hands it to the Docker
daemon, and **a path the daemon cannot open becomes an empty directory rather
than an error** — every submission then runs against nothing and no test fails
visibly. `preflight.sh` refuses a relative one for that reason.

Two more worth reading before the first start:

- **`TRUSTED_PROXY_NETWORKS`** decides whose word the Server takes for a
  visitor's address. It defaults to the Compose network the bundled nginx sits
  on, and must be a **network** address: `172.28.0.5/24` is refused at startup,
  by name, with the address it should have been.
- **`DOCKER_GID`** is the group that owns the daemon's socket. The Runner runs
  unprivileged and reaches the daemon only through it. `preflight.sh` reads the
  real number and tells you if yours is wrong — on Docker Desktop the socket is
  `root:root`, so it is `0`; on a Linux host it is the `docker` group's id:

  ```bash
  getent group docker | cut -d: -f3
  ```

## 2. A certificate

Put `fullchain.pem` and `privkey.pem` in `certs/`. Renewal is whatever you
already use; `/.well-known/acme-challenge/` is served on both ports so an HTTP-01
challenge is never redirected away, and after a renewal:

```bash
docker compose exec nginx nginx -s reload
```

With no certificate, for a first look:

```bash
./scripts/render-tls.sh your.domain
```

**Self-signed, and every browser will say so.** It exists so that a first start
produces a working instance with a warning rather than an nginx that will not
start and an error nobody can connect to anything.

## 3. Start

```bash
./scripts/preflight.sh
docker compose up -d --wait
```

`preflight.sh` refuses now, with a sentence, rather than half way up: an empty
password, a missing token, a CIDR with host bits, a relative work directory, a
`DOCKER_GID` that does not match the socket. `make up` runs it first.

## 4. The administrator

```bash
docker compose exec -it server aj-admin password
```

Then sign in at `https://your.domain/` as **`admin`**.

`aj-admin` runs inside the Server's container and reads its token from the
container's own environment, so the token never enters your shell history. It is
the only supported way to reach the operator's surface: `/api/v1/admin/**`
answers on the Server's own loopback interface, and a request through nginx —
or through the published `127.0.0.1:8080` — arrives as the bridge gateway and
gets a 404. That is measured behaviour, not a guess.

## 5. Approve the Runner

**A new Runner registers and then waits.** It is not a fault and there is no
timeout; nothing is judged until an administrator approves it, which is what
stops somebody attaching a machine of their own to your installation.

In the panel: **Runners**, and approve the one that appeared. Its logs say
`waiting: this Runner has not been approved yet` until you do.

Afterwards, submit something and watch it get a verdict. Until that has happened
once, the installation is not known to work.

## 6. Optionally, the schedule

```bash
./scripts/install-cron.sh --print     # what it would install
./scripts/install-cron.sh
```

Nothing schedules itself. The backup runs at 04:00 local, garbage collection at
06:00, and **the update entry is commented out** — uncomment it only once you
have restored a backup at least once and know it works.

## Pre-configuration, for an installation you do not want to click through

Fill in `preconfig/` before the **first** start and the installation comes up
already configured: its name, its policies, its published documents.
`preconfig/README.md` and `docs/specs/PRECONFIGURATION.md` in the workspace say
what goes in it, and `AlgoJudge-Server/preconfig.example/` is a filled-in
directory to copy from.

**It is read once, at the first start of an empty database.** Afterwards a
change is applied by asking:

```bash
docker compose exec -T server aj-admin config status   # what would change
docker compose exec -T server aj-admin config apply
```

## The other arrangements

### Runners on their own machines

The application host runs `COMPOSE_PROFILES=edge,app,data`; each Runner host
clones this repository and runs `COMPOSE_PROFILES=runner` with

```ini
SERVER_URL=https://your.domain
RUNNER_NAME=runner-lab-a       # different on every host
RUNNER_WORK_DIR=/srv/algojudge/runner-work
```

The Runner opens every connection itself — it needs no inbound port and works
from behind a domestic router. Each one registers separately and needs its own
approval.

**This is the recommended arrangement for a public installation.** In T1 the
Runner sits on the same host as the database, and access to the Docker socket is
equivalent to root on that host.

### Your own reverse proxy

`COMPOSE_PROFILES=app,data`. The Server and the Client are published on
`127.0.0.1:8080` and `127.0.0.1:8082`; point your proxy at them, and:

- route `/api/v1/` to the Server and everything else to the Client, keeping them
  on **one origin** — then `API_BASE_URL=/` needs no CORS at all;
- **do not** route `/api/v1/admin`;
- do not turn a 502/503/504 from the Server into your own page: the Client reads
  those, and a maintenance window is the Server answering `503` with
  `server.maintenance` and a `Retry-After`;
- set `TRUSTED_PROXY_NETWORKS` to **your** proxy's network, not the default;
- send `X-Forwarded-Proto`, or the Server's HTTPS redirect loops.

Serving the two on different origins works, and then `API_BASE_URL` is the
Server's public address and the Client's origin goes in the Server's
`AJ_Cors__AllowedOrigins`.
