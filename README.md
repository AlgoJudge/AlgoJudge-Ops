# AlgoJudge-Ops

AlgoJudge is open-source, self-hosted software for programming contests and
courses, with automatic evaluation of submitted solutions.

The production Compose stack for [AlgoJudge](https://github.com/AlgoJudge), and
the scripts that make a self-hosted installation updatable and backupable.

**This repository is for the administrator of an organization that wants to run
its own AlgoJudge.** It is not one deployment's private configuration; it is a
delivered artifact you clone, configure through `.env`, and run. Two things
follow, and they run through everything here:

- **The default configuration works after `git clone`, `cp .env.example .env`
  and `docker compose up -d`**, with the required values filled in and no
  Compose file edited.
- **It does not impose operational policy.** It ships scripts and an example
  crontab; whether and when to run them is yours. The update entry is commented
  out on purpose.

## Documentation

The full AlgoJudge documentation is available at [docs.algojudge.pl](https://docs.algojudge.pl/).

This README contains repository-specific information about development, building, running, and contributing.

| | |
|---|---|
| [`/en/install/`](https://docs.algojudge.pl/en/install/) | standing an installation up, keeping it running, and getting it back |
| [`/pl/install/`](https://docs.algojudge.pl/pl/install/) | the same in Polish |

**Drift here becomes drift there.** [INSTALL](docs/INSTALL.md),
[OPERATIONS](docs/OPERATIONS.md) and [TROUBLESHOOTING](docs/TROUBLESHOOTING.md)
are what those pages are written from, and nothing checks the two against each
other.

## What is here

| | |
|---|---|
| `compose.yaml` | every service, seven profile names, one file |
| `compose.directories.yaml` | the Runners' cache and scratch as host directories instead of volumes, for a daemon older than Engine 26 |
| `.env.example` | every variable, with no secret values |
| `nginx/` | TLS, one origin for both halves, and the page for when the Client is gone |
| `scripts/` | preflight, backup, restore, update, rollback, maintenance, gc, render-tls, install-cron, check-repository, and the `lib/` they share |
| `cron/` | the suggested schedule, installed only if you ask |
| `docs/` | [INSTALL](docs/INSTALL.md), [OPERATIONS](docs/OPERATIONS.md), [TROUBLESHOOTING](docs/TROUBLESHOOTING.md) |

**Eight profile names, nine services.** `data`, `app`, `server`, `client`,
`edge`, `runner`, `runner-extra` and `external-runner` — the Server and the
Client each carry two, which is what lets one half be brought up on its own. The
nine are `postgres`, `server`, `client`, `nginx`, `external-runner` and a fleet
of four: `runner-1` to `runner-4`, one image and four identities. **`runner`
starts two of them and `runner-extra` the other two.** The reference is two
Runners judging four of one submission's tests at once, on a machine with eight
processors: a submission is answered in the time its slowest test takes rather
than in the sum of them. More judged runs at once than the host has physical
cores does not judge faster and does stop judging accurately, so on a smaller
host run narrower or fewer — `docs/INSTALL.md` has the arithmetic.

## Quick start

```bash
git clone https://github.com/AlgoJudge/AlgoJudge-Ops.git /opt/algojudge-ops
cd /opt/algojudge-ops
git checkout "$(git tag --list 'v*' --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1)"
cp .env.example .env
```

**The newest release, not `main`.** `main` is where the next release is being
written. From here on, follow this README and `docs/INSTALL.md` in the
checkout: they describe the release you have, and this copy may describe the
next one. `scripts/update.sh` moves an installation only from one release to a
newer one — except at `v0.1.0`, whose own `update.sh` predates that rule; move
it to the next release by hand once, with `git fetch --tags` and
`git checkout <tag>`.

Fill in the values `.env.example` marks as having no default, then:

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

**`external-runner` is an addition to any of them, not a fifth one.** Add it
beside `runner` on one host, or run it alone on a machine of its own the way a
Runner can. It is left out of the default because it signs in to somebody else's
judging system under an account there — [docs/INSTALL.md](docs/INSTALL.md) says
what it needs and what it cannot do for you.

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
  — the `algojudge-external-runner` image: a second Runner, forwarding
  submissions to an external judging system and reporting back the verdict that
  system reached. It is the `external-runner` profile, which is **not** in the
  default set because it needs an account at that system
- [AlgoJudge-Docs](https://github.com/AlgoJudge/AlgoJudge-Docs) — the source of
  the documentation site linked under *Documentation* above

## Contributing

Read the [contributing guide](https://github.com/AlgoJudge/.github/blob/main/CONTRIBUTING.md)
before you open a pull request. Report security vulnerabilities privately, as
described in [SECURITY.md](SECURITY.md).

## License

This project's code is licensed under the MIT License.
See [LICENSE](LICENSE).

The documentation is licensed under CC BY 4.0.
See [LICENSE-DOCS](LICENSE-DOCS).

Authors are listed in [AUTHORS.txt](AUTHORS.txt).
