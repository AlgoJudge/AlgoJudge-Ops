# AlgoJudge-Ops

AlgoJudge is open-source, self-hosted software for programming contests and
courses, with automatic evaluation of submitted solutions.

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

## What is here

| | |
|---|---|
| `compose.yaml` | every service, six profile names, one file |
| `.env.example` | every variable, with no secret values |
| `nginx/` | TLS, one origin for both halves, and the page for when the Client is gone |
| `scripts/` | preflight, backup, restore, update, rollback, maintenance, gc, render-tls, install-cron, check-repository, and the `lib/` they share |
| `cron/` | the suggested schedule, installed only if you ask |
| `docs/` | [INSTALL](docs/INSTALL.md), [OPERATIONS](docs/OPERATIONS.md), [TROUBLESHOOTING](docs/TROUBLESHOOTING.md) |

**Six profile names, five services.** `data`, `app`, `server`, `client`, `edge`
and `runner` — the Server and the Client each carry two, which is what lets one
half be brought up on its own.

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

docker compose exec -it server aj-admin password   # set the administrator's password
```

[docs/INSTALL.md](docs/INSTALL.md) is the long version, including the Runner
approval a first installation needs before anything is evaluated.

> **Set `AJ_ADMIN_TOKEN` before the first start.** While it is empty `/admin` is
> closed, and that includes the only way to set the administrator's password —
> which is otherwise twenty random characters nobody was told.

## The four arrangements

Chosen with `COMPOSE_PROFILES` in `.env`; no Compose file is edited for any of
them.

| | `COMPOSE_PROFILES` | |
|---|---|---|
| **T1** | `edge,app,data,runner` | one host, the whole product. The default |
| **T2** | `edge,app,data` + `runner` elsewhere | Runners on their own machines |
| **T3** | `app,data` | your own reverse proxy in front |
| — | `client,server,data` | one half at a time, for debugging and staged updates |

## What it does not do

- **No ACME client.** Certificates are supplied; `/.well-known/acme-challenge/`
  is served on both ports so whatever you already use keeps working.
- **Nothing notifies anybody when a scheduled script fails.**
  [docs/OPERATIONS.md](docs/OPERATIONS.md) says what to watch.

## Related repositories

**This repository holds no application code and builds nothing.** Every image is
pulled from GHCR by tag; what is assembled here is built elsewhere.

- [AlgoJudge-Server](https://github.com/AlgoJudge/AlgoJudge-Server) — the
  `algojudge-server` image, and `aj-admin` inside it
- [AlgoJudge-Client](https://github.com/AlgoJudge/AlgoJudge-Client) — the
  `algojudge-client` image nginx serves
- [AlgoJudge-Runner](https://github.com/AlgoJudge/AlgoJudge-Runner) — the
  `algojudge-runner` image and the four `lang-*` sandboxes it starts
- [AlgoJudge-External-Runner](https://github.com/AlgoJudge/AlgoJudge-External-Runner)
  — a second Runner, forwarding submissions to external judging systems. Not in
  any of the arrangements above: it is deployed beside the stack, like a Runner
  on its own machine
- [AlgoJudge-Docs](https://github.com/AlgoJudge/AlgoJudge-Docs) — the public
  documentation site, whose `/install/` section is written from `docs/` here

## Contributing

Open an issue saying what you expected, what happened, and how to reproduce it.
Or open a pull request against `main`: one subject per pull request, with a note
on what changes and why.

By contributing you agree that your work is licensed under the terms below.

## License

This project's code is licensed under the MIT License.
See [LICENSE](LICENSE).

The documentation is licensed under CC BY 4.0.
See [LICENSE-DOCS](LICENSE-DOCS).

Authors are listed in [AUTHORS.txt](AUTHORS.txt).
