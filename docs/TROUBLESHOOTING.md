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

## `Permission denied (os error 13)` in the Runner

`DOCKER_GID` does not match the group that owns the daemon's socket. The message
comes from deep inside an HTTP client and names neither.

```bash
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock alpine stat -c '%g' /var/run/docker.sock
```

On Docker Desktop that is `0`; on a Linux host it is the `docker` group.
`preflight.sh` runs exactly this and refuses if they disagree.

## nginx will not start

Run the same test CI runs:

```bash
docker run --rm --add-host server:127.0.0.1 --add-host client:127.0.0.1 \
  -v "$PWD/nginx/algojudge.conf:/etc/nginx/conf.d/default.conf:ro" \
  -v "$PWD/nginx/snippets:/etc/nginx/snippets:ro" \
  -v "$PWD/certs:/etc/nginx/certs:ro" \
  nginx:1.27-alpine nginx -t
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
