# When something does not work

Every entry here is something that has actually happened, and most of them look
like a different problem than they are.

## The Server will not start

### `The database has N pending migration(s)`

The schema is behind the image and this Server has not been told it may fix that.
Set `MIGRATE_ON_START=true` in `.env` — **after taking a backup** — or apply the
migrations yourself before starting.

This is also what a **fresh** installation says if the switch is off: an empty
database has every migration pending.

### It exits complaining about `Forwarded`

`TRUSTED_PROXY_NETWORKS` is unset. The Server refuses to start without being told
whose word to take for a visitor's address; `none` is a complete answer for a
Server reached directly.

### It names a network you did not write

You wrote a CIDR with host bits set — `172.28.0.5/24`. .NET normalises that to
`172.28.0.0/24` without a word, which turns "one machine" into "a whole
laboratory", so the Server refuses and names the address you should have written.
`preflight.sh` catches it first.

### `No storage is configured`

`STORAGE_KIND` is empty or misspelled. It is `postgres`, `filesystem` or `s3`.

### It names a storage setting that is empty

`filesystem` needs `STORAGE_PATH`; `s3` needs `STORAGE_ENDPOINT`,
`STORAGE_BUCKET`, `STORAGE_ACCESS_KEY` and `STORAGE_SECRET_KEY`, all four. The
Server refuses at startup naming the one it wanted, and `preflight.sh` refuses
before that. Neither is read while `STORAGE_KIND` is `postgres`, which is why
they ship empty.

## The API answers 404 and you are sure the path is right

**`/health` is not the health endpoint. `/api/v1/health` is.**

Every installation serves the API at `/api/v1`, and the Server answers **404 at
the bare root on purpose** — so that a Client pointed at the wrong path is
corrected rather than answered. A monitor written against `/health` reports the
installation down while it is serving perfectly.

**Through the bundled nginx it is worse**, because `/health` is not a 404 there:
`location /` proxies to the Client, which serves `index.html` for any unknown
path. So `curl https://your.domain/health` returns **200 and an HTML page**.
That is the application's router, not the API.

## `/admin` answers 404 with the right token

It is supposed to. `/api/v1/admin/**` needs the request to arrive on the Server's
**own loopback interface**, and:

- through nginx it arrives as the bridge gateway — 404;
- through the published `127.0.0.1:8080` it *also* arrives as the bridge
  gateway, because that is what a published port does — 404.

Every refusal is the same 404, deliberately, so nothing distinguishes a wrong
token from a wrong route.

The way in is `docker compose exec`:

```bash
docker compose exec -T server aj-admin status
```

If that says `AJ_Admin__Token is not set in this container`, the token was empty
when the container started — set it in `.env` and recreate the Server.

## Nothing is being judged

In order of how often it is each one:

1. **The Runner has not been approved.** Its log says `waiting: this Runner has
   not been approved yet`, and it will say that for ever. Approve it in the panel
   under **Runners**.
2. **`AJ_Sandbox__Image__*` points at images that do not exist.** Compiled in,
   the Runner looks for `algojudge/lang-*:local`, which only a development host
   has. `compose.yaml` sets all four from `REGISTRY` and `RUNNER_TAG`; if you
   overrode them, check `docker images`.
3. **`RUNNER_WORK_DIR` is wrong.** This is the nastiest one, because it fails
   *silently*: the Docker daemon is handed this path directly, and a path it
   cannot open produces an **empty directory** rather than an error. Every job
   then runs against nothing. It must be **absolute**, and it must be a path the
   daemon — not just your shell — can open.
4. **Tags.** A Runner with `RUNNER_TAGS` set is out of the general pool, and work
   with no tags goes to the general pool. Empty means `default` on both sides.
   Note that **tags are read once, at the first registration** — changing the
   variable later does nothing.

## Nothing **external** is being judged

A different list, because the ordinary causes are not the causes here. In order
of how often it is each one:

1. **External judging is off for this installation.** It is off by default, and
   while it is off the Server hands this Runner nothing — an empty queue is not
   an error, so there is nothing in any log. Turn it on in the manager panel, or
   set `instance.externalJudgingEnabled` in `preconfig/` before a first start.
2. **The External Runner has not been approved.** Separately from your other
   Runners: it is a second identity with a second approval.
3. **The problem was not created as an external one.** It has to be typed
   `uva@1` and marked external; a locally typed problem is never offered to a
   forwarding Runner, and that pairing is by equality in both directions.
4. **The version's `props` does not name the archive's problem number.** That is
   refused by name, before anything leaves this installation.
5. **Tags.** As with any Runner, and read once at the first registration.

## The external Runner restarts every few seconds

The account at the judging system is empty or wrong. It refuses while reading its
configuration — before the identity key, before registration — and
`restart: unless-stopped` turns that into a loop.

```bash
docker compose logs external-runner | tail -20
```

The refusal names the setting: `AJ_External__Username is required`. Fill both
values in, and note that `preflight.sh` refuses ahead of this when the profile is
active, so `make up` never gets that far.

**A second cause, with the same symptom and a different fix: the image is older
than the Server.** The log line names a registration rather than a setting —

```
the Server refused the registration: the Server refused with 403: runner.nonce.unknown
```

— and it appears only from the **second** start onwards, because the identity
volume is what makes the Server recognise the key. A Server that requires a
signed re-registration and an image that predates that requirement cannot agree,
the refusal is not one a Runner retries, and `preflight.sh` cannot see it because
the configuration is fine. Pull both images from the same release rather than
letting the moving tags drift; `docs/OPERATIONS.md` under *Update* says why they
have to move together. The sandboxing Runner fails the same way, and its own
entry below says so.

**A password with a leading or trailing space is not the cause.** It is passed
through exactly as written, deliberately — trimming it broke a sign-in once.

## A Runner refuses to start and names a poll or a lease setting

The same loop as above, from a different cause: a Runner checks its intervals
against one another before it does anything, and `restart: unless-stopped` turns
a refusal into a restart every few seconds. Three of these are worth knowing,
and **none of them can be reached with the values this stack ships** — they are
what a `.env` of your own can produce.

```bash
docker compose logs runner | tail -5
docker compose logs external-runner | tail -5
```

- **`the Server refused the registration: … 403: runner.nonce.unknown`.** Not a
  setting at all: this image is older than the Server it is registering against.
  See the external Runner's entry above — the cause and the fix are the same for
  both Runners, and neither is a configuration error.
- **`AJ_Poll__WaitSeconds is N, above the 300 seconds the Server will hold a
  claim open.`** Three hundred is the Server's own ceiling. Asking for more is
  worse than being ignored: a Runner tells a held claim from an immediate answer
  by how long it took, so it would read every held claim as an empty one and
  sleep its backoff after each. Lower it. If the point was to poll less often,
  the setting for that is `AJ_Poll__MaxSeconds`.
- **`AJ_Runner__ProblemTypes names no problem type.`** A lone comma, or a
  trailing one from a paste, leaves the list empty — and an empty list matches
  no problem, so the Runner would register, be approved, heartbeat, show as
  connected and be handed nothing. Leave the variable unset for the default.
  This one is the sandboxing Runner's only: on the external Runner an empty
  value deliberately means the judge's own type.
- **`… make a cycle of N seconds, which does not fit four times inside
  AJ_Lease__RequestSeconds.`** The external Runner renews the leases it holds
  once per cycle, and a cycle is the judge's own interval **plus** the claim the
  Server holds open. A lease that could expire between two renewals is one the
  Server reclaims while a submission is still live at the archive, and the next
  Runner sends it again. Lower either interval, or raise the lease.

This stack does not offer the four external intervals in `.env.example` for
exactly this reason; the image's defaults satisfy all of it.

## The archive says the account does not exist

uHunt answers `0` for a username it does not know, and `0` parses as a number.
That silently made every poll return nothing until the lookup started refusing a
uid of `0` by name. Check the username at the archive itself; it is the same one
a person signs in with.

## A solution reached the archive twice

The External Runner was restarted or killed while a submission was pending there.
The set it is waiting on lives in memory by design, the Server reclaims the lease
and requeues the job, and the job is sent again.

Nothing here can dedupe that — the archive received the first one. What avoids
it is draining before a window; `docs/OPERATIONS.md` under *Maintenance* has the
numbers, including why a 300-second forced close and a fifteen-minute external
job do not meet on their own.

## `Permission denied (os error 13)` in the Runner

**Two different causes produce this one sentence**, and it names neither: it
comes from deep inside an HTTP client or the sandbox layer, with no path and no
number in it. `preflight.sh` checks both, so start there.

**One: the daemon's socket.** `DOCKER_GID` does not match the group that owns it.

```bash
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock alpine stat -c '%g' /var/run/docker.sock
```

On Docker Desktop that is `0`; on a Linux host it is the `docker` group's id.
The runner service runs as root, which opens the socket whatever groups it is
in, so this is only a cause where `compose.yaml` has been edited to drop that.
Where it is, the Runner fails at **startup** and never reaches a job.

**Two: `RUNNER_WORK_DIR` cannot be read by a job container.** The Runner writes
a submission's files there as root; every job container mounts the directory
**read-only** and reads it as uid **65534**. A directory locked down by hand
passes for the Runner and fails for the job, so the socket works perfectly, the
Runner registers, claims a job — and every single one fails at once, which is
how to tell the two apart.

```bash
sudo chmod 755 /srv/algojudge/runner-work
```

Compose creating the directory itself is fine: it makes it as root, mode 0755,
which satisfies both. `preflight.sh` probes both halves — writing as root, then
reading back as 65534.

Measured 2026-09-01 on a stack whose socket was reachable and whose every
submission still failed.

## Every job fails, and the Runner said something about cgroups

**A time limit is decided on processor time**, read from a cgroup the sandbox is
started under. A Runner that cannot read one refuses to start rather than judge
without it, so this is a startup message and not a per-job one:

```bash
docker compose logs runner | head -40
```

Three things it can be, and `preflight.sh` catches the first two before `make
up` starts anything:

| What it says | What to do |
|---|---|
| cgroup version 1 | the host boots a hybrid hierarchy. `systemd.unified_cgroup_hierarchy=1` on the kernel command line, then reboot |
| a cgroup driver it knows neither of | `docker info --format '{{.CgroupDriver}}'` must print `cgroupfs` or `systemd`. Anything else means cgroups are off |
| it cannot read the hierarchy | `compose.yaml` has been edited: the `/sys/fs/cgroup` mount, `cgroup: host` or `user: "0:0"` on the runner service is missing |

**Both cgroup drivers work and neither needs the daemon reconfigured.** A
`native.cgroupdriver=cgroupfs` line in `/etc/docker/daemon.json` does no harm
and is not needed.

## The verdicts are right but no memory is reported

Only on a host using the **`systemd`** cgroup driver, and the Runner says so at
`ERROR` on every start. One slice serves every run there, so a per-run peak is
taken by resetting `memory.peak` — a kernel interface that arrived in **Linux
6.8**. Processor time is unaffected, so every verdict stands.

```bash
uname -r
```

On an older kernel, either accept it or give the daemon the `cgroupfs` driver,
where the peak is read from a fresh cgroup per run and needs nothing beyond
Linux 5.19:

```bash
# /etc/docker/daemon.json
{ "exec-opts": ["native.cgroupdriver=cgroupfs"] }
```

## nginx will not start

Run the same test CI runs:

```bash
docker run --rm --add-host server:127.0.0.1 --add-host client:127.0.0.1 \
  -v "$PWD/nginx/algojudge.conf:/etc/nginx/conf.d/default.conf:ro" \
  -v "$PWD/nginx/snippets:/etc/nginx/snippets:ro" \
  -v "$PWD/certs:/etc/nginx/certs:ro" \
  nginx:1.30-alpine nginx -t
```

`--add-host` is needed because **nginx resolves every upstream while parsing**,
so outside the Compose network it fails with `host not found in upstream
"server:8080"` on a configuration that is perfectly correct.

Two real ones seen here: a **duplicate `proxy_read_timeout`**, because `include`
puts a directive in the including block and nginx refuses duplicates outright
rather than overriding; and a missing certificate, because `certs/` was empty.

## PostgreSQL will not start after an upgrade

**18 moved where the data lives.** `PGDATA` is `/var/lib/postgresql/18/docker`
and the volume belongs one level up at `/var/lib/postgresql`. Every guide written
before 18 says `/var/lib/postgresql/data`, and mounting that makes the container
refuse to start. `compose.yaml` gets it right and
`scripts/check-repository.py` fails if it stops.

The major is pinned on purpose. An unpinned `postgres:latest` rolling over to 18
is how this was found.

## `docker compose ps` shows no health for a Runner

Both Runners show an empty health column, for ever, and neither is a fault. The
Runner's image declares no health check and the External Runner's cannot have one
— it is `distroless/static`, with no shell, no curl and no wget, and it listens
on no port. `docker compose up --wait` therefore calls both ready as soon as they
are running, which they are even while one of them is failing to sign in. Read
their logs.

## The stack is up but the browser shows nothing

- **A browser warning about the certificate** is expected if you ran
  `render-tls.sh`: it is self-signed.
- **A blank page and 404s for `/assets/…`**: the Client image was replaced
  without the Server, or a proxy is caching `index.html`. It is served
  `no-store` for exactly this.
- **The maintenance page**: the Server is in a window. `./scripts/maintenance.sh
  status`, and `off` if it should not be.

## A script says another one is running

```
another AlgoJudge maintenance script is running (pid 1234, lock: …/state/algojudge.lock.d)
```

If pid 1234 is genuinely running, wait. If it is not, the next run takes the lock
over by itself and says so — a lock is never permanently stuck. To clear one by
hand, remove `state/algojudge.lock.d`.

## The backup is not a complete backup

`backup.sh` warns on every run when `STORAGE_KIND` is not `postgres`, and the
`.meta` beside each dump records it as `coverage=INCOMPLETE`. Restoring such a
dump alone gives an installation whose rows point at bytes that are not there —
which presents as a 503 on every download, with nothing naming the cause.

## A restore appeared to work and changed nothing

Read `state/restore.log`. This exact failure happened while this repository was
being written: a Compose invocation failed, its one-line error was reported as a
`pg_restore` warning, and the restore **did nothing at all** while every check
afterwards passed on data that had simply never been touched.

`restore.sh` now counts the tables afterwards and refuses to report success on an
empty database. But the real test is the one that caught it: **change something
first**, then restore, then check the change is gone.
