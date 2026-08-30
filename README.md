# AlgoJudge-Ops

The production Compose stack for [AlgoJudge](https://github.com/AlgoJudge), and
the scripts that make a self-hosted installation updatable and backupable.

**This repository is for the administrator of an organisation that wants to run
its own AlgoJudge.** It is not one deployment's private configuration; it is a
delivered artefact you clone, configure through `.env`, and run. Two things
follow, and they run through everything here:

- **The default configuration works after `git clone`, `cp .env.example .env`
  and `docker compose up -d`**, with three values filled in and no Compose file
  edited.
- **It does not impose operational policy.** It ships scripts and an example
  crontab; whether and when to run them is yours. The update entry is commented
  out on purpose.

## Status

- **Draft, and not yet installable from a clean clone.** Nothing has been
  published to `ghcr.io/algojudge` — no product repository carries a `v*` tag —
  so the images named in `compose.yaml` do not exist yet. The first release, and
  the one-time flip of the seven packages to public, are what close that. See
  *What is not done* below.
- **Verified on 2026-08-30 against images built and tagged locally**, on Docker
  Desktop with Compose v5.3.1 and a local registry standing in for GHCR: a T1
  stack from an empty directory, sign-in through nginx, a Runner registered and
  approved, a maintenance window entered and left with `/api/v1/health` still
  answering 200, a backup restored with a change made in between to prove the
  restore was not a no-op, an update to a new image and a rollback to the
  recorded digest, the retention arithmetic over a 60-day fixture, and the T3
  arrangement without nginx.
- **The Server needs `AJ_Database__MigrateOnStart`**, which landed with this
  work. Without it a fresh database has every migration pending and the Server
  refuses to start — there was no shipped way to apply one.

## What is here

| | |
|---|---|
| `compose.yaml` | every service, five profiles, one file |
| `.env.example` | every variable, with no secret values |
| `nginx/` | TLS, one origin for both halves, and the page for when the Client is gone |
| `scripts/` | preflight, backup, restore, update, rollback, maintenance, gc |
| `cron/` | the suggested schedule, installed only if you ask |
| `docs/` | [INSTALL](docs/INSTALL.md), [OPERATIONS](docs/OPERATIONS.md), [TROUBLESHOOTING](docs/TROUBLESHOOTING.md) |

## Quick start

```bash
git clone https://github.com/AlgoJudge/AlgoJudge-Ops.git /opt/algojudge-ops
cd /opt/algojudge-ops
cp .env.example .env
```

Fill in the three values that have no default — `AJ_ADMIN_TOKEN`,
`POSTGRES_PASSWORD` and `RUNNER_WORK_DIR` — then:

```bash
./scripts/render-tls.sh your.domain    # only if you have no certificate yet
./scripts/preflight.sh
docker compose up -d --wait

docker compose exec -it server aj-admin password   # set the administrator's
```

[docs/INSTALL.md](docs/INSTALL.md) is the long version, including the Runner
approval that a first installation always forgets.

> **Set `AJ_ADMIN_TOKEN` before the first start.** While it is empty `/admin` is
> closed, and that includes the only way to set the administrator's password —
> which is otherwise twenty random characters nobody was told. This is the one
> paragraph here that will cost somebody an evening if it is skipped.

## The four arrangements

Chosen with `COMPOSE_PROFILES` in `.env`; no Compose file is edited for any of
them.

| | `COMPOSE_PROFILES` | |
|---|---|---|
| **T1** | `edge,app,data,runner` | one host, the whole product. The default |
| **T2** | `edge,app,data` + `runner` elsewhere | Runners on their own machines |
| **T3** | `app,data` | your own reverse proxy in front |
| — | `client,server,data` | one half at a time, for debugging and staged updates |

## What is not done

- **No release has been cut.** The first `v*` tag in `AlgoJudge-Client`,
  `-Server` and `-Runner`, and the manual flip of seven `ghcr.io/algojudge`
  packages to public, are the remaining preconditions for the quick start above
  to work from a clean clone.
- **Nothing notifies anybody when a cron script fails.** A backup that has been
  failing for three weeks surfaces during the incident it was meant to survive.
  The channel is undecided; [docs/OPERATIONS.md](docs/OPERATIONS.md) records it.
- **No ACME client.** Certificates are supplied; `/.well-known/acme-challenge/`
  is served on both ports so whatever you already use keeps working.
- **No `Content-Security-Policy`.** The Client writes its runtime configuration
  into `index.html` as an inline script, which a policy worth having would need
  a nonce for. Closing it belongs in `AlgoJudge-Client`.

## The specification

`docs/specs/DEPLOYMENT.md` in the AlgoJudge workspace is the accepted
specification and the decision register — including the corrections made to the
original draft after it was checked against the code.
