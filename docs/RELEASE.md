# Releasing the stack

For whoever cuts the release. An operator standing an installation up wants
[INSTALL.md](INSTALL.md).

## What a tag here is

**It builds nothing, and its tag is still a release.** Every image is pulled
from GHCR by tag, at the versions `.env.example` asks for. A `vX.Y.Z` tag here
is what every installation runs next: `scripts/update.sh` checks out the newest
one on its next run, and the nightly `backup.sh` then runs from it. No workflow
runs on the tag and nothing reaches a registry; pushing it is the release. A
pre-release such as `v0.2.0-rc.1` is never taken.

**Four tags are the whole of it**, in `.env.example` and mirrored as the
defaults in `compose.yaml`:

| | |
|---|---|
| `SERVER_TAG`, `CLIENT_TAG` | `0.2` |
| `RUNNER_TAG` | `0.2`, and it names the four `lang-*` images too |
| `EXTERNAL_RUNNER_TAG` | `0.2`, released on its own schedule |

`POSTGRES_TAG` and `NGINX_TAG` are upstream images and move on their own
reasoning, not on ours.

**The minor, not the moving major.** All four release workflows compute their
tags the same way — `$version ${version%.*} ${version%%.*} latest` — so `v0.2.1`
publishes `0.2.1`, `0.2`, `0` and `latest`. `0.2` takes patches and stops there.

**`0` is what this stack must not use.** Below 1.0 a minor may change what the
one before it did, and 0.2 is not compatible with 0.1 — so the moving major
carries an installation across a break with nothing asked and nothing said.
**This repository is the 0.2 line.** A stack for the next minor is the next
AlgoJudge-Ops release, which is where the upgrade that minor needs belongs.

**A prerelease publishes its own tag alone.** `v0.2.1-rc.1` moves nothing, so a
stack pointed at `0.2` never sees it; testing one means writing the full version
into `.env`.

## What `main` already needs that `0.2` does not yet carry

**This is not a general warning; it is a list, and it has to be emptied before
the next tag.** `main` here runs ahead of the published images on purpose, so
a setting can exist in `compose.yaml` before the image that reads it ships. Most
of that is harmless — a Runner that does not know `AJ_Runner__TestsAtOnce`
ignores it and judges one test at a time, exactly as before.

**The list is empty.** Every key this stack sets is read by the images the four
tags resolve to today.

**An entry belongs here when an image would ignore a key rather than refuse
it**, which is the case that produces no error anywhere. It is settled against
the published image and not against a commit, because the tag is what an
installation pulls:

```bash
docker pull -q ghcr.io/algojudge/algojudge-runner:0.2
docker image inspect ghcr.io/algojudge/algojudge-runner:0.2 \
    --format '{{index .Config.Labels "org.opencontainers.image.version"}} {{index .Config.Labels "org.opencontainers.image.revision"}}'
```

Every image here carries both labels, so that answers which release the tag is
and which commit built it — and the key can then be looked for in that
repository at that revision.

**The Runner reads no arguments at all**, so asking it anything through
`--help` answers with its first refusal about configuration and nothing about
its keys.

## What the next tag changes for the people using it

**The section above is what blocks a tag; this is what a tag changes**, and it
has to be said out loud on release day rather than discovered by somebody whose
score moved. Nothing here stops the release.

### Before they update

- **`.env` belongs to the installation and no checkout touches it.** An
  installation from the 0.1 line still has `SERVER_TAG=0` and the other three,
  which is the moving major this release stopped using. Left alone, that
  installation keeps crossing minors unasked. Tell them to write `0.2`.

- **0.2 is not compatible with 0.1.** The Server and the Client move together:
  a 0.1 Client against a 0.2 Server meets renamed routes, and roles replaced
  permission templates. Pinning one component and not the others is the way to
  a stack that comes up healthy and refuses work.

- **The update carries a destructive migration.** `20260920180000_version_0_2_0`
  is 162 operations, of which 19 drop a column, 10 rename one, 4 drop a table
  and 2 rename one. `update.sh` takes a dump first and `rollback.sh` refuses to
  pretend a rollback undoes it; an operator who has turned `MIGRATE_ON_START`
  off applies it themselves.

- **A host that runs Runners needs Docker Engine 26**, or Podman 5. The host
  directories this stack offered below that floor are gone, so there is no
  arrangement that avoids it. `preflight.sh` refuses before anything starts.

### What they meet afterwards

- **A submission has to end by itself to be accepted.** A checker or an
  interactor finishing no longer stops the program: one that prints its answer
  and keeps writing meets the output limit, one that waits for input that will
  never come meets a time limit, and neither is accepted however satisfied the
  judge was. A judge that **refused** still outranks what stopped the run, so
  its comment survives.

  **It is a verdict change and it moves scores.** What it replaces was not one
  answer: the judge's exit and the output cap were decided in the same loop, so
  the same submission was `Accepted` on an idle host and `Output limit exceeded`
  on a busy one. Code accepted before a contest may be refused after it, and a
  participant who re-submits identical code will see it. A package whose
  problems legitimately keep writing after the judge has seen enough wants a
  judge that reads to the end; most need nothing. `AlgoJudge-Docs` covers it on
  `/runner/problem-types`, `/client/manager/packages` and
  `/client/participant/results`.

- **The cpusets ship empty**, which is every processor the host has. An
  installation that never set them was asking for processors 0 to 7 and failed
  to create a Runner on any smaller machine.

- **A rollback goes back one update and reads `state/previous.lock`.** It is
  written immediately before a swap, so an installation that has not updated
  since moving here has nothing to roll back to, and says so rather than
  reporting a rollback that changed nothing.

- **Installations follow releases, not `main`.** `update.sh` moves the checkout
  only to the newest `vX.Y.Z`. An installation made from `v0.1.0` has that
  tag's `update.sh`, which runs `git pull`, warns on a release checkout and
  stays: move it once by hand, and it follows releases from then on.
  `docs/OPERATIONS.md` has the sequence under *Coming from the 0.1 line*.

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
nothing in it: everything here resolves to `0.2`, which does not exist until
steps 1 to 3 have run.

**All eight packages are public**, read without credentials at `0.2` on
2026-09-21. A package created by its first push is private, so this is a step
that returns with every new image — including `algojudge-external-runner`, which
is built from a private repository and was published anyway, so that profile
needs no `docker login` either. Reading them needs no token of ours:

```bash
image=algojudge-server
token=$(curl -s "https://ghcr.io/token?scope=repository:algojudge/$image:pull&service=ghcr.io" |
    python3 -c "import json,sys; print(json.load(sys.stdin)['token'])")
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.oci.image.index.v1+json' \
    "https://ghcr.io/v2/algojudge/$image/manifests/0.2"
```

## Before the tag

- [ ] **The eight images exist in GHCR under the tag this asks for.** Steps 1 to
      3 above have run, and `docker compose pull` in a clone resolves all eight.

      **`compose pull` reaches six of them.** The four `lang-*` images are not
      services — they are values the Runner is handed — so pull them by name, or
      run `scripts/update.sh`, which does it for you. A Runner pulls one only
      when the host has none at all, so an old copy is used silently and every
      job fails on the missing shim.
- [ ] **CI has run on the commit being tagged.** `.github/workflows/check.yml`
      triggers on `push` to `main` and on `pull_request` only, so **nothing runs
      on a `release/*` branch**. Merge it, or open the pull request, and read that
      run — this repository has no release workflow to refuse a tag that never
      had one.
- [ ] `python3 scripts/check-repository.py` — the same run CI does. **Read the
      count it prints rather than one written here**; it goes up when a check is
      added and a number in this file does not.
      **What it covers**: no committed configuration file assigns a literal to a
      secret-shaped setting; `.env.example` and the compose files name the
      same variables; the two with no default are empty; one PostgreSQL major in
      both files; the four product tags agree across both files; `compose.yaml`
      and `scripts/lib/images.sh` name the same four language images; every
      `AJ_*__Volume` carries the project name and a volume that is declared;
      `make up` fetches the images before starting anything; `pgdata` is
      mounted above `PGDATA`; nginx does not intercept the API, does not answer
      `503` and refuses `/api/v1/admin`; nothing names a bare `/health`; every
      script has a shebang, LF endings and mode `100755` in Git.
      **What it does not**: it reads files and never a registry, so it cannot say
      a tag exists; it forgives any `.env.example` entry a script mentions, so a
      variable a script reads with **no** `.env.example` line would pass; it
      skips `.py` files in the secret scan; it never runs `docker compose`; and
      nothing anywhere reads prose. The three steps below are the rest, by hand.
- [ ] `bash -n` over every script in `scripts/` and `scripts/lib/`. The glob CI
      uses is `scripts/*.sh scripts/lib/*.sh`, and it prints the count it found.
- [ ] **Every arrangement resolves**, with a throwaway `.env` carrying the two
      values that have no default:

      COMPOSE_PROFILES=edge,app,data,runner docker compose config --services

      The `topologies` job in `.github/workflows/check.yml` is the list and the
      expected answers, and it checks eight. **One arrangement is only here**:
      `client,server,data`, which `README.md` documents and that job does not
      check.
- [ ] `./scripts/preflight.sh` refuses what it should on a deliberately wrong
      `.env` — an empty password, an empty or short token, a CIDR with host bits,
      an unknown `STORAGE_KIND`, and the external Runner's account left empty
      while its profile is on. And a daemon below API 1.45 on a host that runs
      Runners, which is a refusal rather than a warning.
- [ ] nginx **starts** with the configuration rather than merely parsing it. CI
      runs `nginx -t`, which is a test and not a start, so do the start here.
      Outside the Compose network it needs `--add-host server:127.0.0.1
      --add-host client:127.0.0.1`: nginx resolves every upstream while reading
      the configuration.
- [ ] **`.env.example` agrees with the compose files and with the scripts, both
      ways.** The checker does the compose half; the script half is the
      `setting NAME` and `${NAME}` reads in `scripts/`. `COMPOSE_PROFILES`,
      `COMPOSE_FILE`, `COMPOSE_PROJECT_NAME` and `ALGOJUDGE_LOCK_HELD` are the
      deliberate exceptions — Compose's own, or internal to the scripts.
- [ ] **No `.env` in the repository, only `.env.example`.** Check the working
      tree, `git ls-files`, and that `.gitignore` still excludes `.env` and
      `.env.*` while un-ignoring `.env.example`. A real one is not read, printed
      or quoted anywhere, here or in a report.
- [ ] **Every image this repository pins is a tag somebody still builds**, read
      by the date it was last built rather than by whether `docker pull` works.
      See *Every image this repository pins*.
- [ ] **The host requirements name the versions this stack actually needs**, not
      a floor that was true once — `INSTALL.md`, under *What the host needs*.
- [ ] The documentation here says what the scripts do: `INSTALL.md`,
      `OPERATIONS.md` and `TROUBLESHOOTING.md` are what the public documentation
      site's `/install/` section is written from, so **drift here becomes drift
      there**. Nothing checks the two against each other, and nothing reads a
      comment in `compose.yaml`, `.env.example`, `nginx/`, `cron/` or `scripts/`.
- [ ] **The sentences that name a release line.** Find them rather than working
      from a list here, which goes stale exactly as they do:

      git grep -nE '0\.[0-9]+(\.[0-9]+)?' -- docs README.md .env.example .github

      Each hit is about the line being released, about one that is still
      current, or stale. `docs/INSTALL.md`'s public-packages paragraph carries
      a line and a date, so it is one of them at every release.

## Every image this repository pins

Ten, and only two of them are somebody else's.

| Image | Where | Whose schedule |
|---|---|---|
| `postgres:${POSTGRES_TAG:-18}` | `compose.yaml`, `.env.example` | upstream |
| `nginx:${NGINX_TAG:-1.30-alpine}` | `compose.yaml`, `.env.example`, `check.yml`, `docs/TROUBLESHOOTING.md`, `scripts/gc.sh` | upstream |
| `algojudge-server`, `algojudge-client` | `compose.yaml` at `${SERVER_TAG:-0.2}` / `${CLIENT_TAG:-0.2}` | ours |
| `algojudge-runner` and `lang-gcc`, `lang-clang`, `lang-python`, `lang-pypy` | `compose.yaml` at `${RUNNER_TAG:-0.2}` | ours |
| `algojudge-external-runner` | `compose.yaml` at `${EXTERNAL_RUNNER_TAG:-0.2}` | ours |

**Ours are settled by the release order above**: `0.2` names the newest patch
of that line in each repository, and the check is that all eight resolve.

**The two upstream ones are the ones that rot quietly**, because a tag goes on
resolving long after anybody stops building it. Read the date, not the pull:

```bash
for i in postgres:18 nginx:1.30-alpine; do
  curl -s "https://hub.docker.com/v2/repositories/library/${i%%:*}/tags/${i##*:}" |
    python3 -c "import json,sys; d=json.load(sys.stdin); print(d['name'], d['last_updated'][:10])"
done
```

nginx numbers even minors stable and odd ones mainline, so 1.30 is stable and
1.31 is mainline. `postgres:18` is the newest major.

**A tag that still resolves is not a tag anybody still maintains**, and nothing
in CI or in `check-repository.py` notices — the check is this paragraph and
somebody doing it.

Raising `NGINX_TAG` is a decision about **three** repositories, not one:
`AlgoJudge-Client` builds its image `FROM nginx:…` and `AlgoJudge-Docs` serves
its own site from another. Know which of the three you are moving.

## After the tag

Nothing publishes, so there is nothing to check in a registry afterwards. What
follows is a real installation: clone the tag, `preflight.sh`, `up -d --wait`,
approve the Runners, and a submission that gets a verdict. **Until that has
happened once, the release is untested where it counts.**

**CI still does not bring the stack up and assert against it**, and since the
images are published that is a decision rather than an impossibility. The
commented block at the foot of `.github/workflows/check.yml` is where it would
go.

The documentation site cuts its `/install/` snapshot on release day, from
`AlgoJudge-Docs`. **A minor gets one or it never does**: the script takes a
minor, refuses a patch version, and refuses to re-cut a directory that exists.

### The public website states this component's version

`algojudge.pl` prints **`Ops v<version>`** in four places — a card badge and a
roadmap item, in each of `src/content/pl.json` and `src/content/en.json` of
`AlgoJudge-Website`. A release makes all four wrong.

**`AlgoJudge-Website` has no CI.** Its fifteen tests run only when somebody types
`npm test`, so nothing reports the mismatch.

`AlgoJudge-Website/tests/content.test.mjs:125` pins the version literal by regex,
`Ops v0\.1\.0`, and hard-codes the five repository keys. Correcting the content
turns that suite red: the test asserts the literal and needs the same edit. Change
content and test in one commit.

The correction is `/website-sync` in the workspace. This runbook's step is to
record that it is owed.
