## What changes and why

<!-- One subject per pull request. If it closes an issue, write "Closes #123". -->

## How it was tested

<!-- The commands you ran, and the installation you tried it on, if any. -->

## Checklist

- [ ] `python3 scripts/check-repository.py` passes.
- [ ] `docker compose config` resolves for every profile the change touches.
- [ ] Changed scripts still parse: `bash -n scripts/*.sh scripts/lib/*.sh`.
- [ ] A change an operator has to act on is described in `docs/`, and the `/install/` pages in AlgoJudge-Docs are updated to match.
- [ ] No secrets, certificates, or `.env` files are committed.
