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
  trusting the flag. Compose v2 is enough because every value here is passed
  through `environment:` — nothing in this repository uses the `env_file:` form
  that needs 2.24.
- **The cgroup tree, and no daemon reconfiguration.** The stack measures a
  submission's processor time and peak memory from a cgroup, because neither is
  available any other way: a container's own cgroup does not outlive it, and the
  runtime API reports no peak on v2. **A time limit is decided on that
  processor time**, so a Runner that cannot read it refuses to start rather than
  judge without it.

  ```bash
  stat -fc %T /sys/fs/cgroup                  # cgroup2fs
  docker info --format '{{.CgroupDriver}}'    # cgroupfs or systemd; both work
  ```

  **Either cgroup driver is fine, and neither needs the daemon reconfigured.**
  Under `cgroupfs` the Runner makes a cgroup per run; under `systemd`, where
  cgroups belong to systemd, it keeps one slice for its whole life and reads each
  run as the change across it.

  `compose.yaml` supplies everything else: **`/sys/fs/cgroup` mounted writable,
  `cgroup: host`** so that the path the Runner reads is the path the daemon
  resolved against, and **`user: "0:0"`** because that tree's directories are
  root's. Write access to the host's cgroup tree is a default here because the
  alternative is a stack that does not judge, and it costs write permission on
  one directory tree rather than a capability. The Runner
  holds the Docker socket in any case, which is root-equivalent on the host, so
  the uid inside its container was never the boundary; `docs/OPERATIONS.md`
  says what follows from that. Nothing it *starts* gains anything: a job
  container still runs as `65534:65534` with every capability dropped.

  **The two backends do not need those equally.** Under `cgroupfs` the Runner
  creates a cgroup, so a writable mount and root are what let it start at all;
  without them it refuses. Under `systemd` it creates nothing and only reads, so
  it starts and judges either way, and what root and the writable mount buy is
  the **peak-memory number**. Measured on all four combinations, 2026-09-03.

  **A `systemd` host can lose that number for a second reason, and it is still
  not the verdict.** The reset of `memory.peak` arrived in **Linux 6.12** — which
  excludes Ubuntu 24.04, shipping 6.8, and includes Debian 13. On an
  older kernel the Runner judges exactly as it should — the verdict is processor
  time — and says at `ERROR` on every start that the number beside it will be
  absent. `cgroupfs` reports it on any kernel from 5.19.

  **`preflight.sh` refuses on a cgroup version below 2**, and on a driver that
  is neither of the two. It refuses rather than warning because the Runner now
  refuses to start without the reading, so a stack that came up with a note
  about it would be a broken installation the operator had been told about
  rather than one they had been stopped from making.
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

**An eighth, if you run the `external-runner` profile, and it is not like the
other seven.** `algojudge-external-runner` is built from a **private**
repository, so whether that package is ever made public is a decision somebody
has to take rather than a step in a list. If it is not, this is the one profile
in this stack that needs a `docker login ghcr.io` before `up`.

> **Not done yet.** No release has been cut, so none of them exists. Until then
> this stack runs only against images built from the product repositories and
> tagged locally — see `docs/OPERATIONS.md`.

## The project name is `algojudge`, and it decides which volumes you get

`compose.yaml` sets `name: algojudge`, so every volume this stack creates is
`algojudge_pgdata`, `algojudge_objects` and so on. That is what makes
`docker compose` in this directory find the installation again without being
told where it is.

It also means **a second run of this stack on the same host attaches the same
volumes** — a rehearsal, a second installation, a copy of the repository
somewhere else. Compose does not warn, and the first sign that anything is
shared is usually `password authentication failed for user "algojudge"`, because
`POSTGRES_PASSWORD` is read only when the volume is first created and the new
`.env` disagrees with the old data.

If you want two of anything on one host, give each its own project name:

```bash
docker compose -p algojudge-staging up -d --wait
```

and pass `-p` to every later command, including the scripts. Better still, put
`COMPOSE_PROJECT_NAME=` in the `.env` beside it, so nobody has to remember.

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
                         # make it and give it to uid 65532 — see below
```

`RUNNER_WORK_DIR` must be absolute because the Runner hands it to the Docker
daemon, and **a path the daemon cannot open becomes an empty directory rather
than an error** — every submission then runs against nothing and no test fails
visibly. `preflight.sh` refuses a relative one for that reason.

**Make it yourself before the first start**, or let Compose make it — either is
fine now:

```bash
sudo mkdir -p /srv/algojudge/runner-work
```

Compose creates a missing bind-mount source as **root, mode 0755**, which is
exactly right: the Runner writes there as root, and every job container mounts
it **read-only** and reads it as uid 65534. What breaks it is a directory locked
down by hand — jobs then fail with `Permission denied (os error 13)` from inside
the sandbox layer. `preflight.sh` probes both halves, writing as root and
reading back as 65534, and says which one failed.

*`chown 65532:65532` also works and costs nothing; the Runner runs as root, so
it is not needed.*

Two more worth reading before the first start:

- **`TRUSTED_PROXY_NETWORKS`** decides whose word the Server takes for a
  visitor's address. It defaults to the Compose network the bundled nginx sits
  on, and must be a **network** address: `172.28.0.5/24` is refused at startup,
  by name, with the address it should have been.
- **`DOCKER_GID`** is the group that owns the daemon's socket. The Runner runs
  as root and reaches the socket whatever groups it is in, so a wrong value no
  longer stops anything and `preflight.sh` only warns about it. `preflight.sh` reads the
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

## How many Runners

**Four, on a host with eight physical cores** — which is what the `runner`
profile starts and what `.env.example` is written for. One Runner judges one
submission at a time, so the count is how many submissions are judged at once,
and the other four cores are for the Server, the database, the daemon and the
operating system.

**More Runners than physical cores does not judge faster, and it stops judging
accurately.** Measured 2026-09-03 on an eight-core host: twelve Runners against
a hundred and fifty submissions returned **fifteen of them as `Time limit
exceeded` when they were inside their limits**, including solutions known to be
correct. Two things cause it and both come from processors being oversubscribed:
a program that is not scheduled still runs out of wall clock, and a program
sharing a core with another spends more processor time on the same work.

So the ceiling is a rule about correctness:

| Physical cores | Runners |
|---|---|
| 4 | 2 |
| 8 | **4** |
| 16 | 8 |

`lscpu` says how many there are — *Core(s) per socket* times *Socket(s)*, which
is **not** the CPU count when a core carries two threads.

To run fewer, remove the services you do not want from `compose.yaml` and leave
their `RUNNER_*_CPUSET` unset. To pin them, see `.env.example`, which explains
how to read a core's threads off the machine rather than guessing them.

### What a submission costs, and why some problems cost twice as much

**A Runner's time goes on starting containers, not on running programs.** Each
test runs in a container of its own — that is what makes the isolation worth
having — and starting one costs more processor time than most solutions spend
in it. A problem with 148 tests is 148 container starts for every submission,
which is why the count of tests, and not the difficulty, decides how long a
submission takes.

**A problem whose answers are judged by a program is two containers per test**,
not one: the submission runs, then the package's own checker runs beside it to
say whether the answer is right. On such a problem a Runner gets through about
half as many submissions in the same time. Any problem type that has to run a
second program alongside the submission has the same shape.

Nothing here needs configuring. It is worth knowing because two installations
with the same hardware and the same number of Runners can differ by a factor of
two in how fast a contest is judged, and the difference is in the problems.

## 5. Approve the Runners

**A new Runner registers and then waits.** It is not a fault and there is no
timeout; nothing is judged until an administrator approves it, which is what
stops somebody attaching a machine of their own to your installation.

In the panel: **Runners**, and approve each of the four that appeared. Their
logs say `waiting: this Runner has not been approved yet` until you do, and an
unapproved Runner is simply idle — the others carry the queue, so a forgotten
approval shows up as a slow installation rather than as an error.

Afterwards, submit something and watch it get a verdict. Until that has happened
once, the installation is not known to work.

## 6. Optionally, an external judge

Skip this unless some of your problems are to be judged by an external archive
rather than here. It needs an **account at that archive**, and every submission
this installation forwards is made under it and stays on it.

In `.env`:

```ini
COMPOSE_PROFILES=edge,app,data,runner,external-runner
EXTERNAL_JUDGE_USERNAME=
EXTERNAL_JUDGE_PASSWORD=
```

Then three things, and **two of them are not in any file here**:

1. **Turn external judging on for the installation.** It is off by default, and
   while it is off the queue is simply empty — no error anywhere, and a Runner
   that looks perfectly healthy. Before the first start, in
   `preconfig/algojudge.yml`:

   ```yaml
   instance:
     externalJudgingEnabled: true
     externalFetchHosts:
       - onlinejudge.org
   ```

   Afterwards it is a manager's switch in the panel.
2. **Approve it in the panel**, separately from your other Runners. It has its
   own identity and its own approval, and it waits with no timeout exactly as
   they do.
3. **A problem has to be created as an external one** — typed `uva@1`, with the
   archive's problem number in its version's `props`. `docs/UVA.md` in
   `AlgoJudge-External-Runner` has the calls.

**The verdict is the archive's opinion, not this installation's.** Their
compilers, their limits, their tests. What you get back is what they said.

It needs **no inbound port, no Docker socket and no work directory**: it dials
out to the Server and to the archive, and accepts nothing. It has no health
check either — the image has no shell to run one with — so `docker compose ps`
shows an empty health column for it for ever, and its log is the instrument:

```bash
docker compose logs -f external-runner
```

## 7. Optionally, the schedule

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
RUNNER_NAME_PREFIX=lab-a       # different on every host
RUNNER_WORK_DIR=/srv/algojudge/runner-work
RUNNER_1_CPUSET=0,1            # one Runner per physical core
RUNNER_2_CPUSET=2,3
RUNNER_3_CPUSET=4,5
RUNNER_4_CPUSET=6,7
```

**The profile starts four Runners**, named `lab-a-1` to `lab-a-4` here. The
prefix has to differ per host, or two machines' Runners appear in the panel
under one set of names. On a host with fewer than eight physical cores, run
fewer: see *How many Runners* above.

The Runner opens every connection itself — it needs no inbound port and works
from behind a domestic router. Each one registers separately and needs its own
approval, so a four-Runner host is four approvals.

**This is the recommended arrangement for a public installation.** In T1 the
Runner sits on the same host as the database, and access to the Docker socket is
equivalent to root on that host.

The External Runner runs the same way — `COMPOSE_PROFILES=external-runner` with
`SERVER_URL` and its own `EXTERNAL_RUNNER_NAME` — and the argument for moving it
is weaker: it starts no containers, holds no socket and runs nothing untrusted.
What it does hold is a credential to somebody else's service, so the host it sits
on is one whose `.env` you are willing to trust with that.

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
Server's public address, the Client's origin goes in the Server's
`AJ_Cors__AllowedOrigins`, and **`APP_BASE_URL` is where the browser reaches the
Client**. Leaving that last one empty on two origins is the mistake worth naming:
a sign-in through an identity provider ends at a bare `/activities`, which the
browser resolves against the API's origin and where it finds a 404.

### If you use LTI

`AJ_PublicApiUrl` is **deliberately not set by this stack**, and setting it in
`compose.yaml` would be worse than leaving it out: two of the four places that
read it accept an empty string as an answer, and an environment variable set to
nothing is not the same as one that was never set. Launches and platforms
registered by hand work without it, from the address of the request.

**Dynamic registration is the exception** — it refuses unless the value resolves
to an absolute `http(s)` address. If you use it, write an override rather than
editing `compose.yaml`:

```yaml
# state/lti.compose.yaml
services:
  server:
    environment:
      AJ_PublicApiUrl: https://your.domain/api/v1
```

```bash
COMPOSE_FILE="compose.yaml:state/lti.compose.yaml" docker compose up -d
```

**Put that value in `.env`, not on one command line.** `COMPOSE_FILE` is how
these scripts learn about an overlay at all: `update.sh`, `rollback.sh` and
`preflight.sh` all compose without naming files, so an overlay given once with
`-f` is invisible to every one of them — and the next `update` or `rollback`
composes without it and takes its services away with `--remove-orphans`.

**And the frame header has to go**, if your LMS is on a different name from this
installation. `X-Frame-Options: SAMEORIGIN` — which `nginx/snippets/security-headers.conf`
sets, and which is the whole of the frame policy here — allows framing only from
the **same** origin, so a Moodle at `moodle.example.edu` framing this application
at `algojudge.example.edu` is refused exactly as `DENY` would refuse it. Measured
in a browser, not deduced.

Replace it with a policy that can name the platform:

```nginx
# instead of the X-Frame-Options line
add_header Content-Security-Policy "frame-ancestors https://moodle.example.edu" always;
```

Only an LMS and an installation served from **one** origin — routed by path — work
under the shipped value.

**A word about overlays, because the trap is silent.** Add services under **new
names**. A service redefined in an overlay does not replace the base definition,
it **merges** with it — `profiles` included — so an overlay naming
`external-runner` under a different profile leaves it selected by both, and
starts it under a profile you never wrote. Measured on Compose v5.3.1:
`profiles: ['external-runner', 'runner']`.
