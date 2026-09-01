# Releasing the stack

For whoever cuts the release. An operator standing an installation up wants
[INSTALL.md](INSTALL.md).

## This repository has no version of its own

**It builds nothing and publishes nothing.** Every image is pulled from GHCR by
tag, and the only versions that matter here are the ones `.env.example` asks
for. A `v0.1.0` tag on this repository is a name for a known-good stack somebody
can clone — no workflow runs on it, and nothing reaches a registry.

**Four tags are the whole of it**, in `.env.example` and mirrored as the
defaults in `compose.yaml`:

| | |
|---|---|
| `SERVER_TAG`, `CLIENT_TAG` | `0` |
| `RUNNER_TAG` | `0`, and it names the four `lang-*` images too |
| `EXTERNAL_RUNNER_TAG` | `0`, released on its own schedule |

`POSTGRES_TAG` and `NGINX_TAG` are upstream images and move on their own
reasoning, not on ours.

**Why `0` and not `1`.** A release tagged `v0.1.0` publishes `0.1.0`, `0.1`, `0`
and `latest`; the moving major of the 0.1 line is `0`. Asking for `1` would
name a tag no release creates, and `docker compose pull` would find nothing. Below 1.0 a minor may change what the
one before it did, so `0` follows those too: an installation that wants only
fixes writes `0.1`, and one that wants to decide every version writes `0.1.0`.

## Before the tag

- [ ] **The eight images exist in GHCR under the tag this asks for.** They are
      published by four other repositories, and this one cannot be tested against
      a registry with nothing in it. The order is Server and Client, then the
      Runners, then this.
- [ ] `python3 scripts/check-repository.py` — the same run CI does, including
      that `.env.example` and `compose.yaml` agree.
- [ ] `bash -n` over every script in `scripts/` and `scripts/lib/`.
- [ ] **Every arrangement resolves**, with a throwaway `.env` carrying the three
      values that have no default:

      COMPOSE_PROFILES=edge,app,data,runner docker compose config --services

      and the same for `edge,app,data`, `runner`, `app,data`, and both external
      ones. The `topologies` job in `.github/workflows/check.yml` is the list and
      the expected answers.
- [ ] `./scripts/preflight.sh` refuses what it should on a deliberately wrong
      `.env` — an empty password, a CIDR with host bits, a relative work
      directory.
- [ ] nginx **starts** with the configuration rather than merely parsing it.
- [ ] The documentation here says what the scripts do: `INSTALL.md`,
      `OPERATIONS.md` and `TROUBLESHOOTING.md` are what the public
      documentation site's `/install/` section is written from, so drift here
      becomes drift there.

## After the tag

Nothing publishes, so there is nothing to check in a registry afterwards. What
follows is a real installation: clone the tag, `preflight.sh`, `up -d --wait`,
and a submission that gets a verdict. **Until that has happened once, the
release is untested where it counts.**

The documentation site cuts its `/install/` snapshot on release day, from
`AlgoJudge-Docs`.
