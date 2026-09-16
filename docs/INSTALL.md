# Installing AlgoJudge

From an empty directory to an installation that judges a submission.

> **Set `AJ_ADMIN_TOKEN` before the first `up`.** While it is empty
> `/api/v1/admin/**` is closed, and that includes the endpoint that sets the
> administrator's password. The seeded `admin` account's password is twenty
> random characters that are never logged, printed or stored anywhere readable —
> so an installation started without this token has no administrator anybody can
> sign in as, and the fix is to drop the database and start again.

## What the host needs

- **Docker with Compose v2.15.0 or later**, and cgroup **v2**. The Runner
  refuses to start on v1 unless deliberately overridden, and CI asserts v2 rather
  than trusting the flag.

  **2.15.0 is the floor because of `cgroup: host`**, which `compose.yaml` sets on
  the Runner and which Compose first shipped in that version; `up -d --wait`,
  used by `install.sh` and `update.sh`, needs 2.1.1. Nothing here uses the
  `env_file:` form that would ask for 2.24 — every value is passed through
  `environment:`.
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
  run as the change across it. Under both, a memory limit is enforced on a further
  cgroup made **inside** each judged container, holding the submission alone —
  which is why this mount has to be writable whichever driver is in use. The
  Runner proves that at start under both drivers, by making a cgroup and taking
  it away again, and **refuses to start** when it cannot: a Runner that came up
  on a read-only tree would register, answer the protocol, and then fail every
  job it claimed.

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

  **Both backends need those, and neither starts without them.** A memory limit
  is enforced on a cgroup holding the submission alone, made per judged run, and
  that one is the Runner's to make under either driver — so a tree it cannot
  write into is a refusal at start rather than a stack that comes up and fails
  every submission.

  **A `systemd` host below Linux 6.12 loses less than it sounds like.** That
  kernel brought the reset of `memory.peak` — which excludes Ubuntu 24.04,
  shipping 6.8, and includes Debian 13. Neither a verdict nor a submission's own
  numbers depend on it: a judged run's peak is read from the cgroup made for that
  run, which is fresh. What is absent is the peak of the runs that are nobody's
  submission — a build, a checker, an interactor — and the Runner says so on
  every start, as a warning carrying `peak memory will not be reported`.
  `cgroupfs` reports every one of them from 5.19.

  **`preflight.sh` refuses on a cgroup version below 2**, and on a driver that
  is neither of the two. It refuses rather than warning because the Runner now
  refuses to start without the reading, so a stack that came up with a note
  about it would be a broken installation the operator had been told about
  rather than one they had been stopped from making.
- **The command set the scripts use.** `bash` and `openssl` are the ones worth
  installing deliberately; the rest are on any Linux host that has coreutils:
  `awk`, `sed`, `stat`, `sha256sum`, `mktemp`, `date`, `find`, `du`, `df`, `cut`,
  `tr`, `grep`, `sort`, `head`, `tail`, `wc`.

  **`sed -i` and `stat -c` are the GNU spellings**, so a BSD or macOS host is not
  one of these hosts. `git`, `flock` and `crontab` are optional and each degrades
  with a message rather than failing: no `git` means no revision in a backup's
  manifest, no `flock` means two scripts can overlap, no `crontab` means the
  schedule is yours to install.
- **Disk for backups**, ideally on a **different filesystem** from the
  PostgreSQL volume. On one filesystem no reserve setting can guarantee that a
  backup will not starve the database it is backing up.
- **A bounded container log driver is not a host requirement.** `compose.yaml`
  sets `logging:` on every service itself — Docker's `local` driver, bounded by
  `LOG_MAX_SIZE` and `LOG_MAX_FILES` in `.env` — so the stack does not depend on
  what the daemon is set to, and there is nothing to do before installing.

  The daemon's own default is an unbounded JSON file, and it used to be the
  commonest way one of these hosts filled its disk. **Setting a bound on the
  daemon is still worth doing** for whatever else runs on the machine; it is
  simply not this installation's business.

  One consequence, if you ship logs somewhere: `docker logs` and `docker compose
  logs` read `local` exactly as they read `json-file`, but a collector that tails
  `*-json.log` off the host filesystem will not find these. Change the driver in
  `compose.yaml` if you run one.

## The images, and why a new one will not be pullable

The release workflow publishes to `ghcr.io/algojudge`, and **a package created by
its first push is private**. Until somebody sets it to Public once, `docker pull`
answers `denied` and needs a token — which defeats the point of there being no
registry login in these instructions. The workflow cannot do it; a person with
access to the organisation's packages must.

**For 0.1 there is nothing to do: all eight are public.** Read without any
credentials on 2026-09-08, at `0` and at `0.1.0`:

| | |
|---|---|
| `algojudge-server`, `algojudge-client` | the application |
| `algojudge-runner` and `lang-gcc`, `lang-clang`, `lang-python`, `lang-pypy` | judging |
| `algojudge-external-runner` | the `external-runner` profile |

The last is built from a **private** repository and was published anyway, so that
profile needs no `docker login` either.

This section stays because the rule outlives the release: **the next image this
organisation publishes starts private again**, and the symptom is a `denied` on
`docker compose pull` in an installation that is otherwise correct.

```bash
docker pull ghcr.io/algojudge/algojudge-server:0    # no login, from anywhere
```

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

**`RUNNER_CACHE_DIR` has a default and the same rule applies to it.** It is
where this host's Runners keep each package they have downloaded, unpacked once
and built the checker of once, between them; a judge's container mounts it, so
the daemon has to be able to open it too. Leave it alone unless `/srv` is not
where this installation keeps its data, and keep it **out of**
`RUNNER_WORK_DIR`, whose first-level directories the scheduled clean-up removes
by age.

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

## How many Runners, and how wide

**Two, judging two of one submission's tests at a time each** — which is what
the `runner` profile starts and what `.env.example` is written for, on a machine
whose eight processors are four cores of two threads:

```ini
RUNNER_1_CPUSET=0,1,2,3
RUNNER_2_CPUSET=4,5,6,7
RUNNER_TESTS_AT_ONCE=2
```

**A lane wants a whole core, and the width follows from that** rather than from
the processor count. Measured 2026-09-15 on one submission of 72 tests: 196 ms a
test in lanes of a core against 318 ms in lanes of a thread, which put 610 of 864
tests over a limit none of them reached at the wider setting. A time limit is
processor time, so that is correct solutions refused. Per submission the two are
the same speed — 11.2 s against 12.5 s — so the thin arrangement buys throughput
and pays for it in the verdicts. The Runner warns at start, once per lane that
holds a thread whose sibling went elsewhere.

A Runner judges one submission at a time, so the count of Runners is how many
submissions are judged at once. **`RUNNER_TESTS_AT_ONCE` is how many of that
submission's tests it judges together**, each in a **lane** — a piece of the
Runner's `cpuset` with a measurement home of its own — so a participant waits
for the slowest of the tests running together rather than for the sum of them.
The two settings spend the same processors: two Runners of four lanes answer one
submission sooner, four Runners of one lane answer four submissions at once.

**`runner` starts `runner-1` and `runner-2`; `runner-3` and `runner-4` are
behind `runner-extra`.** Add that profile to `COMPOSE_PROFILES` and give the two
of them cpusets of their own, on a host with the processors to spare.

**The rule for dividing a machine is one Runner per group of processors, and one
lane per processor in the group.** A lane wants a processor of its own, and the
Runner refuses a width its cpuset cannot give one each.

**Whether a lane also gets a *core* of its own is your choice, and the Runner
cannot check that half.** Two different Runners on one core take each other's
execution units, and so do two lanes on the two threads of one core: the program
then spends more processor time on the same work, and a limit is processor time.
The values above divide processors, so on a host whose eight are eight cores
every lane has one, and on a host whose eight are four cores with two threads
every core carries two lanes — a submission answered sooner, at a real cost in
the number its verdict is decided by.

To give every lane a core instead, write the sibling pairs next to each other
and let the cut fall between them: the Runner cuts a cpuset into lanes **in the
order it is written**, so `RUNNER_1_CPUSET=0,8,1,9,2,10,3,11` at a width of four
is four lanes of one core each where cpu0's partner is cpu8.
`cat /sys/devices/system/cpu/cpu0/topology/thread_siblings_list` says which it
is here — `0-1` on one kind of host, `0,8` on another — and a list written for
the first is exactly wrong on the second.

**More judged runs at once than the host has physical cores does not judge
faster, and it stops judging accurately.** Measured 2026-09-03 on an eight-core
host: twelve Runners against a hundred and fifty submissions returned **fifteen
of them as `Time limit exceeded` when they were inside their limits**, including
solutions known to be correct. Two things cause it and both come from processors
being oversubscribed: a program that is not scheduled still runs out of wall
clock, and a program sharing a core with another spends more processor time on
the same work. **Lanes count in that ceiling exactly as Runners do** — twelve
Runners of one lane and three Runners of four are the same twelve judged runs.

So the ceiling is a rule about correctness, and what it counts is the lanes:

| Physical cores | Runners | `RUNNER_TESTS_AT_ONCE` |
|---|---|---|
| 4 | 1 | 4 |
| 8 | **2** | **4** |
| 16 | 4, with `runner-extra` | 4 |

`lscpu` says how many processors there are, and *Core(s) per socket* times
*Socket(s)* how many physical cores — which is **not** the CPU count when a core
carries two threads.

**A cpuset confines the Runners and reserves nothing for anybody else.** The
Server, the database and the daemon are unpinned, and the host places them where
it likes — including on the processors a Runner is judging on. Where judging
must not crowd them, give the Runners narrower sets, and lower
`RUNNER_TESTS_AT_ONCE` with them: a Runner asked for more lanes than its cpuset
names refuses to start.

**A width costs memory as well as processors** — about 1.3 GiB per Runner at
four lanes on 256 MiB problems, before the inputs. `docs/OPERATIONS.md` breaks
that down under *What a Runner holds at once*.

To run one Runner rather than two, remove `runner-2` from `compose.yaml` and
clear `RUNNER_2_CPUSET`: `preflight.sh` counts a cpuset against the width
whether or not a service is still reading it.

### What a submission costs, and why some problems cost twice as much

**A Runner's time goes on starting containers, not on running programs.** Each
test runs in a container of its own — that is what makes the isolation worth
having — and starting one costs more processor time than most solutions spend
in it. A problem with 148 tests is 148 container starts for every submission,
which is why the count of tests, and not the difficulty, decides how long a
submission takes.

**A lane is what buys some of that back.** A Runner of four lanes has four of
those starts in flight at once, so the submission is answered in the time its
slowest lane takes rather than in the sum of its tests. It is the same work on
the same processors — what changes is how long one participant waits for it.

**A problem whose answers are judged by a program is two containers per test**,
not one: the submission runs, then the package's own checker runs beside it to
say whether the answer is right — in the **same lane**, so a width does not
change that ratio. On such a problem a Runner gets through about half as many
submissions in the same time. Any problem type that has to run a second program
alongside the submission has the same shape.

Nothing here needs configuring. It is worth knowing because two installations
with the same hardware and the same number of Runners can differ by a factor of
two in how fast a contest is judged, and the difference is in the problems.

## 5. Approve the Runners

**A new Runner registers and then waits.** It is not a fault and there is no
timeout; nothing is judged until an administrator approves it, which is what
stops somebody attaching a machine of their own to your installation.

In the panel: **Runners**, and approve each of the two that appeared — four,
with `runner-extra`. Their logs say `waiting: this Runner has not been approved
yet` until you do, and an unapproved Runner is simply idle — the others carry
the queue, so a forgotten approval shows up as a slow installation rather than
as an error.

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
RUNNER_1_CPUSET=0,1,2,3        # one Runner per group of cores,
RUNNER_2_CPUSET=4,5,6,7        # one lane per core in the group
RUNNER_TESTS_AT_ONCE=2
```

**The profile starts two Runners**, named `lab-a-1` and `lab-a-2` here;
`runner-extra` adds `lab-a-3` and `lab-a-4` on a host with the processors for
them. The prefix has to differ per host, or two machines' Runners appear in the
panel under one set of names. On a host with fewer physical cores, run narrower
or fewer: see *How many Runners, and how wide* above.

The Runner opens every connection itself — it needs no inbound port and works
from behind a domestic router. Each one registers separately and needs its own
approval, so a two-Runner host is two approvals.

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

**The two origins must be the same site** — the same registrable domain and the
same scheme. `algojudge.example` beside `api.algojudge.example` is one site, and
everything works: measured 2026-09-06, a page on one drawing the figures in a
problem statement from the other, every one answered `200 image/png`.
`algojudge.example` beside `algojudge-api.other` is **two** sites, and then
nobody can sign in at all. The session cookie is `SameSite=Lax`; a browser will
not keep it when the sign-in answer comes from another site, so `POST
/identity/login` answers `200` with a `Set-Cookie`, the browser stores nothing,
the next request is `401`, and the application sits on the login screen **with no
error anywhere**. A `Domain` on the cookie does not help: a server may only widen
one to its own parent domain, never to somebody else's.

**On two origins, the API's address must not send `X-Frame-Options`** — and the
bundled `security-headers.conf` sends `SAMEORIGIN`, so a proxy that carries these
headers in front of the API breaks something that has nothing to do with frames.
A problem statement in PDF is drawn by the Client with `<object
data="…/api/v1/files/…">`, which is an embedding like an iframe: on two origins
the API is a foreign origin, and `SAMEORIGIN` refuses it. **Silently** —
`X-Frame-Options` writes nothing to the console, unlike the CSP form, so the
symptom is a statement that shows an empty box with a *download* link and a
console with nothing in it. Measured 2026-09-08 in Chromium, four header values
against the same document.

Two ways out, and this stack takes neither for you because it does not know your
addresses: send **no** frame policy on the API's address — embedding it gains an
attacker nothing, since the session cookie is `SameSite=Lax` and a foreign
embedder is answered `401` — or send `frame-ancestors` naming the Client's origin
**and every LMS platform**, because an LTI launch puts both in the ancestor
chain. What must not happen is the API answering `X-Frame-Options` at all.

`AJ_Cors__AllowedOrigins` is not set by this stack, for the reason
`AJ_PublicApiUrl` is not — an empty list entry is not the same as none. Write an
overlay, as that one does:

```yaml
# state/origins.compose.yaml
services:
  server:
    environment:
      AJ_Cors__AllowedOrigins__0: https://algojudge.example
```

One index per origin. `AJ_Cors__AllowedOrigins=a,b` binds **zero** of them,
silently, and every call from the browser then fails where no log is looking.

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
