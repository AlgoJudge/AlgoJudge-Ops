# Shortcuts. Everything here is a `docker compose` or a script you can run
# yourself; nothing is hidden behind it.
#
# **`up` runs preflight first**, so the ordinary path is checked whether or not
# anybody remembers that script exists.

.PHONY: help up down restart logs ps preflight backup restore update rollback gc maintenance-on maintenance-off status check

help:
	@echo 'up               preflight, then start what COMPOSE_PROFILES names'
	@echo 'down             stop everything (volumes are kept)'
	@echo 'logs             follow the logs'
	@echo 'ps               what is running, and whether it is healthy'
	@echo 'status           the maintenance switch'
	@echo 'backup           one dump, verified, then rotation'
	@echo 'restore DUMP=…   put a dump back (destroys the current database)'
	@echo 'update           pull, back up, swap, roll back if it does not come up'
	@echo 'rollback         return to the images in state/current.lock'
	@echo 'gc               reclaim what this installation left behind'
	@echo 'check            repository checks'

preflight:
	./scripts/preflight.sh

up: preflight
	docker compose up -d --wait

down:
	docker compose down

restart:
	docker compose restart

logs:
	docker compose logs -f --tail 100

ps:
	docker compose ps

status:
	./scripts/maintenance.sh status

maintenance-on:
	./scripts/maintenance.sh on "$(REASON)" --wait-closed

maintenance-off:
	./scripts/maintenance.sh off

backup:
	./scripts/backup.sh

restore:
	@test -n "$(DUMP)" || { echo 'usage: make restore DUMP=backups/algojudge-….dump' >&2; exit 2; }
	./scripts/restore.sh "$(DUMP)"

update:
	./scripts/update.sh

rollback:
	./scripts/rollback.sh

gc:
	./scripts/gc.sh

check:
	python3 scripts/check-repository.py
