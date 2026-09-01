# Pre-configuration

**Read once, at the first start of an empty database, and never again on a
boot.** Fill this directory in before the first `docker compose up` and the
installation comes up already configured — its name, its policies, its published
documents — rather than waiting for somebody to click through the panel.

An installation that has been running does not re-read it. A file changed
afterwards is applied by asking for it:

```bash
docker compose exec -T server aj-admin config status   # what would change
docker compose exec -T server aj-admin config apply    # change it
```

## What may be in here

```
algojudge.yml            required; states the format and the version
pages/                   welcome, home, terms, privacy, cookies, accessibility
                         (`<kind>-<language>.md` for a translation)
logo.svg | .png | .webp  the mark; `logo-en.svg` for one per language
theme.yml                the colours and the typeface
fonts/                   one WOFF2 file per face the theme names
```

**`theme.yml` and `fonts/` arrived on 2026-08-30** and this file did not name
them until 2026-09-01. The theme file is byte for byte what the panel publishes,
so one exported there drops in here unchanged — which is also what lets the
checksum comparison work on it. Publish the faces before the theme that names
them.

**One setting worth knowing about by name.** External judging is off until the
installation turns it on, and this is where it is turned on before a first start:

```yaml
instance:
  externalJudgingEnabled: true
  externalFetchHosts:
    - onlinejudge.org
```

Without it the External Runner registers, is approved, polls, and is handed
nothing — with no error anywhere. `docs/INSTALL.md` has the rest of that path.

**It adds and never withdraws.** A setting the files leave out is left alone
rather than reset, and a document this directory does not carry stays published.

`docs/specs/PRECONFIGURATION.md` in the AlgoJudge workspace is the specification,
and `preconfig.example/` in `AlgoJudge-Server` is a filled-in directory to copy
from. **What an installation puts here is its own** and is not committed to this
repository — see `.gitignore`.
