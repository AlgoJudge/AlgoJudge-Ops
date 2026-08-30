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

**It adds and never withdraws.** A setting the files leave out is left alone
rather than reset, and a document this directory does not carry stays published.

`docs/specs/PRECONFIGURATION.md` in the AlgoJudge workspace is the specification,
and `preconfig.example/` in `AlgoJudge-Server` is a filled-in directory to copy
from. **What an installation puts here is its own** and is not committed to this
repository — see `.gitignore`.
