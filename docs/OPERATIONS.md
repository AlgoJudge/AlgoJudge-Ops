# Operating an installation

What to run, when, and what each thing costs.

## Maintenance: taking it out of service without stopping it

```bash
./scripts/maintenance.sh on "nightly backup" --wait-closed
./scripts/maintenance.sh status
./scripts/maintenance.sh off
```

The Server owns this. Turning it on enters **`draining`** immediately: the
participant API refuses with `503`, but a Runner may still finish and report the
job it already claimed. It reaches **`closed`** when nothing is running, or after
`Maintenance:ForceAfterSeconds` — 300 by default — whichever comes first.

**`closed` is the only level at which the database is safe to touch.** At
`draining` a Runner may still be writing a result, and a dump taken then is
internally consistent but silently loses that result on restore. `--wait-closed`
is what waits.

**A forced close loses nothing.** The abandoned job keeps its lease, the lease
expires, the reaper puts it back on the queue — one evaluation done twice,
against an operator held hostage by one wedged Runner.

**With the `external-runner` profile on, that sentence needs a qualification.**
The evaluation done twice is then a submission made twice **on somebody else's
service, under this installation's account there** — the archive has already
received it, and what is repeated is the sending rather than the judging. The
External Runner keeps the set it is waiting on in memory only, so a restart
during a window loses it and every job in it is sent again.

An external job may legitimately be held for fifteen minutes, and
`Maintenance:ForceAfterSeconds` is 300, so the two do not meet on their own.
Before a window that will restart that container: raise `ForceAfterSeconds` past
`AJ_External__PendingTimeoutSeconds`, wait for the queue to be quiet, or accept
the duplicate.

### The way that is not a way

**Do not put a maintenance page in front of nginx.** It is the obvious idea and
it breaks three things at once:

- `/api/v1/health` must answer **200 at every maintenance level**. The Server's
  own container health check greps it, so a 503 there has Docker kill the process
  you are deliberately keeping alive; `docker compose up --wait` polls it; and it
  is what the Client and every Runner poll to learn they may come back.
- The Client already **has** a maintenance page — in this installation's
  branding and language — drawn from the Server's `server.maintenance` refusal. A
  static page from the proxy replaces it with something worse and hides the
  reason.
- A proxy refusing everything refuses the **Runner** too, so nothing in flight
  can finish and the drain never completes. Every window would then cost an
  interrupted evaluation, which is the whole thing it exists to avoid.

`nginx/algojudge.conf` says `proxy_intercept_errors off` under the API location
for this reason, and `scripts/check-repository.py` fails if that changes.

## Backup

```bash
./scripts/backup.sh                 # what cron runs
./scripts/backup.sh --quiesce       # with the installation closed
```

**`pg_dump` does not need the Server stopped.** It produces a transactionally
consistent dump from a running database, so the nightly run costs no outage and
`--quiesce` is off by default. Use it before a migration or a restore rehearsal,
where "no evaluation in flight" is worth an outage.

Every run: dumps to a `.partial`, verifies it, renames it, writes a `.meta`
beside it, rotates, and reports any overdue hold.

### What the dump does and does not cover

**With `STORAGE_KIND=postgres` — the default — the dump is the whole of the
installation's state.** That is why it is the default: one thing to back up.

With `filesystem` or `s3` it is not, and `backup.sh` says so on every run rather
than producing something that restores to an installation whose rows point at
bytes that are not there. Back up the store in the same window, or move the files
into the database:

```bash
docker compose exec -T server aj-admin storage status
docker compose exec -T server aj-admin storage migrate
```

**Where `filesystem` puts them**: the named volume `objects`, mounted at
`/var/lib/algojudge/objects` in the Server's container and reachable from the
host as `algojudge_objects`. `STORAGE_PATH` moves the path inside the container,
not the volume. `s3` puts them wherever `STORAGE_ENDPOINT` points, and backing
that up is that service's business rather than this stack's.

### A dump is not a configuration file

**It carries every password hash, every uploaded file, and the key ring that
mints session cookies.** Handle it as you would handle the database itself.

If one leaks, the sessions minted under those keys are the urgent part:

```bash
docker compose exec -T server aj-admin keyring revoke --yes
```

That signs everybody out, everywhere, and is the point of it.

### Retention: two bounds, and neither alone is enough

The count policy answers *how far back can I go*; the size budget answers *how
much disk will this cost*. A backup directory that fills the disk stops
PostgreSQL writing, which turns a safety mechanism into the outage it was meant
to prevent.

| Bound | Set by | |
|---|---|---|
| Count | `BACKUP_PRESET` | how far back the history reaches |
| Size | `BACKUP_MAX_TOTAL_GB` | how much disk it may cost |
| Floor | `BACKUP_MIN_KEEP` | never dropped, whatever the size says |

**One dump is taken per run.** `daily`, `weekly` and `monthly` are not three
kinds of dump on three schedules — they are three **survival rules** applied to
the one series of files that exists, and a file no rule claims is deleted.

| Rule | Keeps |
|---|---|
| `KEEP_DAILY` | the newest dump of each of the last N **days on which a dump exists** |
| `KEEP_WEEKLY` | the newest of each of the last N ISO weeks |
| `KEEP_MONTHLY` | the newest of each of the last N months |

They are a **union of sets, not a sum of counts**: one file can satisfy all
three and is then stored once. Measured on a 60-day fixture, `standard`
(7/4/2) settles at **eleven** files, not the thirteen a naive sum suggests —
today's dump is simultaneously the newest daily, the newest of its week and the
newest of its month. The exact number moves with where today falls in the week.

**"Days on which a dump exists", not "the last N calendar days."** A host
switched off for a fortnight would, under the calendar reading, come back with no
daily history at all; under this one it comes back holding its seven most recent
dumps, merely spread over a longer span.

**Rotation order**: the count policy first, then, while the directory still
exceeds the size budget, drop the oldest remaining — but **never below the
floor**. If even the floor will not fit, the run says so and keeps what it has.

**And if there is not room for the new dump at all, the run fails and makes
none.** Deleting a known good backup in order to attempt a new one is the single
worst thing a backup script can do.

### Deep history is a named hold, not deep rotation

```bash
./scripts/backup.sh --keep end-of-semester --until 2027-03-01
```

Writes into `backups/keep/`, which **rotation never touches**. For the end of a
contest, the end of a term, and the moment before a large migration.

**`--until` is mandatory and it is a review date, not a deletion date.** Nothing
in `keep/` is ever removed automatically — deleting a copy somebody deliberately
preserved is not a decision a cron job may take. What happens instead is that
every overdue hold is **reported on every run**, so each deep copy stays a
conscious, renewed decision. That is what stops named holds quietly
reintroducing the deep history the size bound removed: a rotation reaching two
months means nothing if an unreviewed hold from three years ago sits beside it.

It is also why the monthly count is two rather than six. A rotated monthly dump
does not record *why* it exists, so months later nobody can judge whether it may
go; a labelled hold with a review date answers both questions by itself.

`keep/` counts towards the size budget and is warned about past half of it,
precisely because nothing deletes it for you.

### Contests

One dump a day means a failure during a round costs the whole round. Run
`backup.sh` **before a round opens and after the results are frozen**, and
shorten the interval for the duration of a long contest. A dump taken while a
round is open is safe — `pg_dump` does not block.

### Erasure, and how long somebody stays in the backups

**Deleting an account is anonymization, and backups are not re-anonymized.** A
dump taken before it still carries the person's name and address, so restoring it
returns somebody who exercised erasure in the meantime. Identity is not confined
to the user row either: it also sits in source comments, question bodies and
filenames, all of which a dump preserves untouched.

**Backups are not edited to remove a person.** Excising rows destroys the
property that makes a dump a backup — that it restores to a consistent state —
and leaves nobody able to say whether it still works. What is done instead:

1. **The window is short.** `standard` reaches about two months.
2. **Named holds carry a review date**, so the ceiling is not silently lifted by
   an archive nobody revisits.
3. **The privacy policy says so**: that backups exist, that they are restored
   only whole and only after a failure, and that data leaves them by the copy
   expiring rather than by surgery on it.

Point 3 is **not an Ops file**. The privacy policy is this installation's own
document and you are its data controller. The template shipped with the product
must mention backups, or an operator who publishes it as-is has published an
incomplete description of what their system does.

Keep `BACKUP_PRESET` no longer than the retention window your policy states.

## Restore

```bash
./scripts/restore.sh backups/algojudge-20260830-040000.dump
```

Closes the installation, stops the Server and the Client, restores, checks that
something actually arrived, starts them again, waits for healthy, reopens.

Before it does anything it reads the `.meta`: the checksum, whether the dump
covered the files, and **which schema it holds**. An older dump under a newer
Server is not an error — with `MIGRATE_ON_START=true` the Server migrates it
forward on the next start — but it is one-way, and you are told before rather
than after.

**Neither Runner is stopped by it**, deliberately — they hold no state a restore
touches, and stopping the sandboxing one would abandon whatever it is running.
Both simply fail to renew their leases while the Server is down and give their
jobs up; the Server reclaims those and requeues them, so a restore of a few
minutes costs nothing. A long one costs the External Runner's pending set, which
is the duplicate submission the *Maintenance* section describes.

**Rehearse it.** A backup with no tested restore is a hypothesis. The honest
rehearsal is on a spare host: clone this repository, copy `.env` and one dump,
`docker compose up -d --wait`, `./scripts/restore.sh`, then sign in and look at
something you recognise.

## Update

```bash
./scripts/update.sh
./scripts/update.sh --dry-run
```

1. `git pull` — new Compose files and scripts, never new image versions.
2. `docker compose pull` — **the longest step, and it costs no downtime.**
3. Nothing new? Stop. Nothing is closed.
4. Back up.
5. Close, and wait for the drain.
6. `up -d`, wait for healthy.
7. Healthy: record the digests. Not healthy: roll back.
8. Reopen, and prune only this project's images.

The outage is steps 5 to 7 — measured at about eighteen seconds on a small
installation, most of it the drain.

**Versions are tags in `.env` and digests in `state/current.lock`.** The tag says
what was asked for; the digest says what is running, and is what a rollback
restores. Digests cannot live in this repository — it is a product many
organisations deploy independently, and none of them can commit to it.

### Rollback

```bash
./scripts/rollback.sh
```

Restores exactly the images in `state/current.lock`, whatever the tags point at
now, through an override at `state/rollback.compose.yaml`. **Bring the stack up
with both files** until the cause is fixed, or a plain `up` puts the new images
back.

**A rollback does not undo a migration.** If the update moved the schema,
`state/last-migration` records it and `rollback.sh` refuses to be quiet about it:
an older Server against a newer schema does not start, and the only way back is
restoring the dump taken immediately before — which loses everything written
since.

### The Runner during an update

**The Runner does not handle `SIGTERM` — it ignores it.** Measured 2026-09-01:
`docker stop -t 60` waited the full sixty seconds and then killed it, exit 137.
It is killed, and its job goes back on the queue when the lease expires.

**So `stop_grace_period` is a cost, not a courtesy**, and it is paid on every
`down`, every `stop` and every update. It shipped at 300s until 2026-09-01,
which is where five minutes of silence at the end of `docker compose down` came
from; it is 30s now, and nothing is lost by that — the job returns to the queue
whichever second the Runner died in. Measured on the same stack: **302 s before,
32 s after**.

**Two things stop that change reaching an installation that already exists**,
and both are worth knowing before you conclude it did not work:

- **Docker records the timeout on the container when it is created.** Until the
  containers are recreated — the next `up` after a pull, or `up --force-recreate`
  — `down` still waits the old value, whatever `compose.yaml` now says.
  `docker inspect -f '{{.Config.StopTimeout}}' <container>` says which one it
  holds.
- **`.env` wins over the new default.** An installation set up before this
  carries `RUNNER_STOP_GRACE=300s` in its own `.env`, and that is still what it
  gets. Change it there.

A clean drain is `maintenance.sh on --wait-closed` on the **Server** first, which
`update.sh` does. Never `docker stop` on a Runner as a way of being careful.

**The External Runner reaches the same conclusion by a different route.** It
handles no `SIGTERM` either, so it has no grace period at all — one would buy
nothing. What it loses when it dies is not an evaluation in progress but a list
of submissions an archive has not answered for yet, and each of those is sent to
that archive a second time when the job is requeued. The drain is the answer
there too, and the paragraph under *Maintenance* is the one to read first.

## Garbage collection

```bash
./scripts/gc.sh
```

Work directories older than `GC_TMP_RETENTION_DAYS`, exited job containers
nothing will collect, images **filtered to this project's label**, and this
repository's own logs.

**Never a global prune.** The host may run other things, and
`docker system prune` does not know that.

**Neither cache volume is swept here**, because neither needs it: the Runner
bounds `runner-cache` at 10 GiB and the External Runner bounds
`external-runner-cache` at 256 MiB, both from inside. They are named volumes, so
they survive `down` and an image change — and deleting either costs a download
rather than a job.

**`VACUUM` and `REINDEX` are deliberately absent.** Different risk, different
runtime — a `REINDEX` holds locks a contest would notice — and autovacuum already
does the routine part. Putting them in a nightly job is its own decision.

## The schedule

`cron/algojudge.cron`, installed only by `./scripts/install-cron.sh`.

**Anchored to this host's local time, not UTC.** 04:00 means 04:00 to whoever
operates the machine, which keeps the work inside the organisation's actual quiet
hours rather than a fixed offset that drifts against them twice a year.

- `CRON_TZ` is honoured by Vixie cron and cronie and is **not** portable to every
  implementation. `install-cron.sh` finds out by installing, and falls back with
  a warning rather than silently scheduling against a different clock.
- **04:00 and 06:00 are safe in the EU**, where the change happens at 01:00 UTC,
  so neither hour is ever skipped or repeated. **This does not generalise** —
  some zones switch at midnight. Check your own before moving them.
- **06:00 here is not the Server's 06:00.** The Server's file collector is
  anchored to **UTC** (`Files:CollectAtHourUtc`), so in Warsaw the two are two
  hours apart in winter and three in summer. Harmless, and worth knowing before
  somebody assumes one schedule governs both.

### Nobody is told when a run fails

**This is the largest open question in this repository.** A backup that has been
failing for three weeks surfaces during the incident it was meant to survive.
Point `MAILTO` at somebody who reads it, or feed `/var/log/algojudge/*.log` into
whatever this organisation already watches. Choosing a channel here would be
inventing policy for you.

## External judging

Only with the `external-runner` profile. Nothing below applies to an
installation that does not use it.

**The verdict is somebody else's.** The submission is forwarded to an external
archive, compiled by their compilers under their limits against their tests, and
what comes back is what they said. This installation records it and names the
judge behind it; it cannot explain it, re-run it, or disagree with it.

**Two switches, and neither is in `.env`.** External judging is a setting of the
installation — off by default, set in `preconfig/` before the first start or in
the manager panel afterwards — and the Runner needs an administrator's approval
like any other. Until both, its queue is empty: no error, no warning, and a
container that looks perfectly healthy. That combination is the first thing to
check when nothing external is being judged.

**One account, and everything is on it.** Every submission this installation
forwards is made under the account in `EXTERNAL_JUDGE_USERNAME` and stays on it
at that archive, permanently. Rotating the password is a change at the archive
and then in `.env`; there is nothing to revoke here.

**One process, one judge.** A second archive is a second service with its own
account and its own identity volume, not a second value in a list.

**It has no health check and no shell.** `docker compose ps` shows an empty
health column for it for ever; `docker compose exec` does not work on it at all.
`docker compose logs -f external-runner` is the whole of the instrumentation, and
it says what it registered as, what it declared, and what it is waiting for.

## Security, stated rather than implied

**The External Runner is the least dangerous container here and the only one
holding somebody else's credential.** It runs nothing untrusted, starts no
containers, holds no socket and listens on no port — but `.env` carries a working
account at an external archive, which is why that file is `chmod 600` and why
rotating it is a change to make at the archive rather than here. Every submission
forwarded under it stays on that account.

**Access to the Docker socket is equivalent to root on the host.** The Runner
needs it to start job containers. In T1 that host also runs the database, so
anybody who escapes a job container is on the machine holding every submission
and every password hash.

The mitigations that are real: the Runner runs unprivileged and reaches the
daemon through a group; job containers get no socket, no network, and CPU, memory
and pid limits; and **for a public installation, Runners belong on machines of
their own** (`COMPOSE_PROFILES=runner`), where the worst case is a machine that
holds nothing.

Everything else: only nginx publishes a port to the network; PostgreSQL has no
host port at all; `.env` holds every secret and should be `chmod 600`; and the
images are public in GHCR, so **nothing sensitive may ever be baked into one**.

## Running against locally built images

Until a release exists, `ghcr.io/algojudge/*` is empty. To run this stack,
build the product repositories and tag them as published:

```bash
docker build -f AlgoJudge-Server/AlgoJudge.Server/Dockerfile -t ghcr.io/algojudge/algojudge-server:1 AlgoJudge-Server
docker build -t ghcr.io/algojudge/algojudge-client:1 AlgoJudge-Client
docker build -t ghcr.io/algojudge/algojudge-runner:1 AlgoJudge-Runner
for lang in gcc clang python pypy; do
    docker build -t "ghcr.io/algojudge/lang-$lang:1" "AlgoJudge-Runner/images/$lang"
done

# Only for the `external-runner` profile.
docker build -t ghcr.io/algojudge/algojudge-external-runner:1 AlgoJudge-External-Runner
```

**`-f` is relative to where you are standing, not to the context.** The line
above said `-f AlgoJudge.Server/Dockerfile` until 2026-09-01 and failed from the
workspace root with `lstat AlgoJudge.Server: no such file or directory` — the
only one of the eight builds that had a path in it, and the only one that was
wrong.

**Rebuild rather than reuse a tag you already have.** These images are pinned by
a moving tag, so a stale local `:1` is silently whatever you built last month —
`docker image inspect --format '{{.Created}}'` before trusting one.

An image built this way carries none of the `org.opencontainers.image.*` labels
a release sets, so `gc.sh` and `update.sh` will not prune it. That is convenient
here and is not something to rely on.

`compose.yaml` then runs unmodified. `update.sh` needs a registry to pull from —
a local `registry:2` with `REGISTRY=localhost:5000/algojudge` is how the update
and rollback paths were verified on 2026-08-30.
