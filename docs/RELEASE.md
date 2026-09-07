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

**Why `0` and not `1`.** All four release workflows compute their tags the same
way — `$version ${version%.*} ${version%%.*} latest` — so `v0.1.0` publishes
`0.1.0`, `0.1`, `0` and `latest`, and the moving major of the 0.1 line is `0`.
Asking for `1` would name a tag no release creates, and `docker compose pull`
would find nothing. Below 1.0 a minor may change what the one before it did, so
`0` follows those too: an installation that wants only fixes writes `0.1`, and
one that wants to decide every version writes `0.1.0`.

**A prerelease publishes its own tag alone.** `v0.1.0-rc.1` moves nothing, so a
stack pointed at `0` never sees it; testing one means writing the full version
into `.env`.

## Eight images, four repositories, and this one last

1. **AlgoJudge-Server** and **AlgoJudge-Client** — independent of each other,
   either order, or together.
2. **AlgoJudge-Runner**, which publishes `algojudge-runner`, `lang-gcc`,
   `lang-clang`, `lang-python` and `lang-pypy` together.
3. **AlgoJudge-External-Runner**, which publishes `algojudge-external-runner`.
4. **AlgoJudge-Ops**, last.

**Step 3 follows step 2 even though neither pulls the other's image.** The
external Runner takes `aj-protocol` from `AlgoJudge-Runner` **by git revision**
(its `Cargo.toml`), and both Dockerfiles pin the same Rust base digest — so the
revision it names should be the commit the Runner released, and the two digests
should still match when it is tagged. That is a source dependency, settled by
reading those files, not by a registry.

**Step 4 is the hard one.** This stack cannot be tested against a registry with
nothing in it: everything here resolves to the moving major `0`, which does not
exist until steps 1 to 3 have run.

**Seven of the eight packages need a one-time flip to public**, or `docker pull`
needs a token and the instructions in `INSTALL.md` do not work as written. The
eighth, `algojudge-external-runner`, is built from a private repository, so
whether it is ever made public is a decision somebody takes rather than a step in
a list — until it is, that one profile needs `docker login ghcr.io`.

## Before the tag

- [ ] **The eight images exist in GHCR under the tag this asks for.** Steps 1 to
      3 above have run, and `docker compose pull` in a clone resolves all eight.
- [ ] **CI has run on the commit being tagged.** `.github/workflows/check.yml`
      triggers on `push` to `main` and on `pull_request` only, so **nothing runs
      on `release/0.1.0`**. Merge it, or open the pull request, and read that
      run — this repository has no release workflow to refuse a tag that never
      had one.
- [ ] `python3 scripts/check-repository.py` — nine checks, the same run CI does.
      **What it covers**: no committed configuration file assigns a literal to a
      secret-shaped setting; `.env.example` and `compose.yaml` name the same
      variables; the three with no default are empty; one PostgreSQL major in
      both files; the four product tags agree across both files; `pgdata` is
      mounted above `PGDATA`; nginx does not intercept the API, does not answer
      `503` and refuses `/api/v1/admin`; nothing names a bare `/health`; every
      script has a shebang, LF endings and mode `100755` in Git.
      **What it does not**: it reads files and never a registry, so it cannot say
      a tag exists; it forgives any `.env.example` entry a script mentions, so a
      variable a script reads with **no** `.env.example` line would pass; it
      skips `.py` files in the secret scan; it never runs `docker compose`; and
      nothing anywhere reads prose. The three steps below are the rest, by hand.
- [ ] `bash -n` over every script in `scripts/` and `scripts/lib/`. Ten of them.
- [ ] **Every arrangement resolves**, with a throwaway `.env` carrying the three
      values that have no default:

      COMPOSE_PROFILES=edge,app,data,runner docker compose config --services

      and the same for `edge,app,data`, `runner`, `app,data`, both external ones,
      and `client,server,data` — which `README.md` documents and the `topologies`
      job in `.github/workflows/check.yml` does not check. That job is the list
      and the expected answers for the other six.
- [ ] `./scripts/preflight.sh` refuses what it should on a deliberately wrong
      `.env` — an empty password, an empty or short token, a CIDR with host bits,
      a relative work directory, an unknown `STORAGE_KIND`, and the external
      Runner's account left empty while its profile is on.
- [ ] nginx **starts** with the configuration rather than merely parsing it. CI
      runs `nginx -t`, which is a test and not a start, so do the start here.
      Outside the Compose network it needs `--add-host server:127.0.0.1
      --add-host client:127.0.0.1`: nginx resolves every upstream while reading
      the configuration.
- [ ] **`.env.example` agrees with `compose.yaml` and with the scripts, both
      ways.** The checker does the compose half; the script half is the `setting
      NAME` and `${NAME}` reads in `scripts/`. `COMPOSE_PROFILES`,
      `COMPOSE_FILE`, `COMPOSE_PROJECT_NAME` and `ALGOJUDGE_LOCK_HELD` are the
      deliberate exceptions — Compose's own, or internal to the scripts.
- [ ] **No `.env` in the repository, only `.env.example`.** Check the working
      tree, `git ls-files`, and that `.gitignore` still excludes `.env` and
      `.env.*` while un-ignoring `.env.example`. A real one is not read, printed
      or quoted anywhere, here or in a report.
- [ ] **The pinned upstream images are still receiving updates.** `POSTGRES_TAG`
      and `NGINX_TAG` move on somebody else's schedule and nothing here notices
      when a branch reaches end of life. Read what is recorded below, then check
      it again.
- [ ] **The host requirements name the versions this stack actually needs**, not
      a floor that was true once — `INSTALL.md`, under *What the host needs*.
- [ ] The documentation here says what the scripts do: `INSTALL.md`,
      `OPERATIONS.md` and `TROUBLESHOOTING.md` are what the public documentation
      site's `/install/` section is written from, so **drift here becomes drift
      there**. Nothing checks the two against each other, and nothing reads a
      comment in `compose.yaml`, `.env.example`, `nginx/`, `cron/` or `scripts/`.
- [ ] **The sentences saying nothing has been released.** Three go stale the
      moment `0.1.0` exists: `docs/INSTALL.md` (*Not done yet*, under the
      public-packages section), `docs/OPERATIONS.md` (*Running against locally
      built images*), and the closing comment in `.github/workflows/check.yml`.

## What was checked on 2026-09-07, and against what

`release/0.1.0` at `f5deca9`, two commits ahead of `main` and none behind. Local
tools: Docker 29.6.2, Compose v5.3.1, Python 3.14.6, GNU bash 4.4.

- **`check-repository.py`**: nine checks, nothing to report.
- **`bash -n`**: ten scripts parse.
- **The seven arrangements** each resolve to the services they should, including
  `client,server,data`.
- **`preflight.sh`** on a deliberately wrong `.env`: five problems, exit 1,
  nothing started. On a good one with `external-runner` on and no credentials:
  one problem, exit 1.
- **nginx started** with the shipped configuration and served `/healthz` 200 on
  both ports, answered `/api/v1/admin` with 404, and accepted the health check
  `compose.yaml` gives it — on `nginx:1.27-alpine` (1.27.5) and again on
  `nginx:1.30-alpine` (1.30.4), which starts clean on the same files.
- **`.env.example`**: 63 variables, every one read by `compose.yaml` or a script,
  and every `setting NAME` and `${NAME}` in `scripts/` described there.
- **No `.env`** in the working tree or in `git ls-files`; `.gitignore` covers
  both spellings.
- **`POSTGRES_TAG=18` is current.** 18 is the newest major and 18.6 the newest
  patch, and the `18` tag resolves to it.
- **`NGINX_TAG=1.27-alpine` is not.** The 1.27 mainline branch reached end of
  life on 2025-06-24; the tag still pulls, frozen at 1.27.5 from 2025-04-16.
  Stable is 1.30 (1.30.4), mainline 1.31 (1.31.5). It is written in four places
  here — `compose.yaml`, `.env.example`, `docs/TROUBLESHOOTING.md` and
  `.github/workflows/check.yml` — and `AlgoJudge-Client`'s published image is
  `FROM nginx:1.27-alpine`, so raising one is a decision about both.
- **The Compose floor is higher than `INSTALL.md` says.** `compose.yaml` uses
  `cgroup: host`, which `docker/compose` first shipped in **v2.15.0**, and
  `up -d --wait` needs v2.1.1. *What the host needs* says *Compose v2 or later*.
- **The host command set is larger than `INSTALL.md` lists.** Beyond `bash`,
  `openssl`, `find`, `du` and `df`, the scripts use `awk`, `sed`, `stat`,
  `sha256sum`, `mktemp`, `date`, `cut`, `tr`, `grep`, `sort`, `head`, `tail` and
  `wc`, with `git`, `flock` and `crontab` optional and each degrading with a
  message. `sed -i` and `stat -c` are the GNU spellings.
- **`python3` is a maintainer's tool, not an installation's**: `check-repository.py`
  is CI and `make check`. Green on 3.12 in CI and on 3.14.6 here.
- **Names, paths and commands cross-checked mechanically**: every `scripts/*`
  reference in the documentation resolves to a file that exists, every `aj-admin`
  subcommand named here exists in the Server's script, and the crontab and
  `OPERATIONS.md` agree on the schedule. The prose itself was not proofread line
  by line.

**Not checked, because it cannot be yet**: no image was pulled and no stack was
brought up against `ghcr.io/algojudge`, which is empty; the one-time flip of the
packages to public has not been exercised; and no installation has been stood up
end to end from a tag. The seven arrangements were resolved with `docker compose
config`, which expands and validates but pulls nothing.

## After the tag

Nothing publishes, so there is nothing to check in a registry afterwards. What
follows is a real installation: clone the tag, `preflight.sh`, `up -d --wait`,
approve the Runners, and a submission that gets a verdict. **Until that has
happened once, the release is untested where it counts.**

Then the two things this repository has been holding until images exist:

- the commented block at the foot of `.github/workflows/check.yml` — whether CI
  now brings the stack up and asserts against it;
- `docs/OPERATIONS.md`'s *Running against locally built images*, which is the
  workaround for having no registry.

The documentation site cuts its `/install/` snapshot on release day, from
`AlgoJudge-Docs`.
