#!/usr/bin/env python3
"""What this repository must say about itself, checked rather than remembered.

    python3 scripts/check-repository.py

It reads only committed files: it never starts the stack, never reads a real
`.env`, and needs nothing installed.
"""

import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# A setting whose value is a secret. Not "no high-entropy strings", which
# reports on every base64-looking word and gets ignored: in a file that reaches
# a deployment, a secret-shaped setting is never assigned a literal. It is an
# expansion, or it is empty.
SECRET_NAMES = re.compile(
    r"(PASSWORD|PASSWD|SECRET|TOKEN|_KEY|APIKEY|CREDENTIAL)", re.IGNORECASE
)

# **The value must *end* in the expansion, not merely start with one.**
# `${FOO}` is fine; `${FOO}-and-then-a-literal` is how a real value eventually
# gets in beside a decoy. Relaxing this to "starts with" is the change to refuse.
NOT_A_VALUE = re.compile(r"^\s*(|\$\{[^}]+\}|\$[A-Za-z_][A-Za-z0-9_]*)\s*$")

# **A literal is allowed only when it says in its own text that it is not a
# secret** — `admin-token-development-only`, `ci-only-not-a-deployment`,
# `Moodle-development-only-1!`.
#
# The alternative was exempting `.github/workflows/`, which would have let a real
# secret through in the one place a workflow would need one.
SAYS_IT_IS_NOT_A_SECRET = re.compile(
    r"(ci-only|development-only|not-a-secret|not-a-deployment)", re.IGNORECASE
)


def read(name):
    return (ROOT / name).read_text(encoding="utf-8")


def no_secret_committed(problems):
    """No committed file assigns a literal to a secret-shaped setting.

    `.env` is skipped and `.env.example` is not: a real `.env` reports on every
    correctly configured stack, and a check that cries on a clean stack is one
    that gets ignored on a dirty one.
    """
    # **Only the files that reach a deployment**: configuration, compose, the
    # crontab and the scripts. Scanning `.py` as well would flag this file's own
    # `SECRET_NAMES` regex.
    carries_configuration = {".yaml", ".yml", ".sh", ".conf", ".cron"}

    for path in sorted(ROOT.rglob("*")):
        if not path.is_file():
            continue
        parts = path.relative_to(ROOT).parts
        if parts[0] in {".git", "backups", "state", "certs", "runner-work"}:
            continue
        if path.name.startswith(".env") and path.name != ".env.example":
            continue
        if path.suffix not in carries_configuration \
                and path.name not in {".env.example", "Makefile"}:
            continue

        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue

        # **Two spellings, because the file most likely to carry a real secret
        # uses the second one.** Splitting on `=` alone lets
        # `AJ_Admin__Token: hunter2` pass in `compose.yaml`, which is precisely
        # where somebody pastes a value "just to test it".
        yaml = path.suffix in {".yaml", ".yml"}

        for number, line in enumerate(text.splitlines(), 1):
            stripped = line.strip()
            if stripped.startswith("#"):
                continue

            if "=" in stripped:
                name, _, value = stripped.partition("=")
            elif yaml and ":" in stripped:
                name, _, value = stripped.partition(":")
            else:
                continue

            name = name.strip().lstrip("-").split()[-1] if name.strip() else ""
            if not SECRET_NAMES.search(name):
                continue
            # A compose `${VAR:?message}` carries prose after the `?`; that is a
            # message, not a value.
            value = re.sub(r"\$\{([^}:]+)(:[?-][^}]*)?\}", r"${\1}", value.strip())
            if SAYS_IT_IS_NOT_A_SECRET.search(value):
                continue
            if not NOT_A_VALUE.match(value):
                problems.append(
                    f"{path.relative_to(ROOT)}:{number}: {name} is assigned a literal. "
                    "A secret-shaped setting must be empty or an expansion."
                )


def env_example_and_compose_agree(problems):
    """Every variable compose expands appears in `.env.example`, and back."""
    compose = read("compose.yaml")
    example = read(".env.example")

    # `${NAME}`, `${NAME:-default}`, `${NAME:?message}`. Not the `AJ_`-prefixed
    # keys, which are the Server's own settings written out in full.
    used = {
        match.group(1)
        for match in re.finditer(r"\$\{([A-Z][A-Z0-9_]*)[:}-]", compose)
    }
    # Compose's own, which an operator sets but this file does not describe.
    used -= {"COMPOSE_PROFILES"}

    described = {
        match.group(1)
        for match in re.finditer(r"^#?\s*([A-Z][A-Z0-9_]*)=", example, re.MULTILINE)
    }

    for name in sorted(used - described):
        problems.append(
            f".env.example does not mention {name}, which compose.yaml expands. "
            "An operator has no way to learn it exists."
        )

    # `.env.example` legitimately describes settings read by the scripts rather
    # than by compose.
    from_scripts = set()
    for script in sorted((ROOT / "scripts").rglob("*.sh")):
        text = script.read_text(encoding="utf-8")
        from_scripts |= set(re.findall(r"\bsetting ([A-Z][A-Z0-9_]*)", text))
        from_scripts |= set(re.findall(r"\$\{([A-Z][A-Z0-9_]*)[:}-]", text))
    for name in sorted(described - used - from_scripts - {"COMPOSE_PROFILES"}):
        problems.append(
            f".env.example describes {name}, which nothing in compose.yaml or "
            "scripts/ reads. It is advice that does nothing."
        )


def secrets_have_no_defaults(problems):
    """The three that must not start with a working value, do not have one."""
    example = read(".env.example")
    for name in ("AJ_ADMIN_TOKEN", "POSTGRES_PASSWORD", "RUNNER_WORK_DIR"):
        match = re.search(rf"^{name}=(.*)$", example, re.MULTILINE)
        if match is None:
            problems.append(f".env.example has no {name} line at all.")
        elif match.group(1).strip():
            problems.append(
                f".env.example ships {name}={match.group(1)!r}. These three have no "
                "safe default: an installation must be made to choose."
            )


def one_postgres_major(problems):
    """The PostgreSQL major agrees everywhere it is written.

    It is written twice, and the two disagreeing is not cosmetic: 18 moved the
    data directory, so a stack whose compose default and whose `.env` differ
    across that boundary starts a container that refuses to open its volume.
    """
    compose = re.search(r"POSTGRES_TAG:-(\d+)", read("compose.yaml"))
    example = re.search(r"^POSTGRES_TAG=(\d+)", read(".env.example"), re.MULTILINE)
    if compose and example and compose.group(1) != example.group(1):
        problems.append(
            f"compose.yaml defaults PostgreSQL to {compose.group(1)} and .env.example "
            f"says {example.group(1)}."
        )


def the_product_tags_agree(problems):
    """Every product image tag says the same thing in both files.

    **This is the drift that shipped.** `compose.yaml` and `.env.example` both
    default the four product images, and both were written `1` while the prose
    five lines above the values in `.env.example` explained that a `v0.4.2`
    release publishes `0.4.2`, `0.4`, `0` and `latest`. At 0.1.0 there is no
    `1` tag at all, so a first installation's `compose pull` would have failed
    on every product image with `manifest unknown`.

    `POSTGRES_TAG` had this check and the four that move with our own releases
    did not, which is the wrong way round: theirs is somebody else's version
    and moves rarely, ours moves every release.
    """
    compose = read("compose.yaml")
    example = read(".env.example")
    for name in ("SERVER_TAG", "CLIENT_TAG", "RUNNER_TAG", "EXTERNAL_RUNNER_TAG"):
        here = re.search(r"\$\{%s:-([^}]*)\}" % name, compose)
        there = re.search(r"^%s=(.*)$" % name, example, re.MULTILINE)
        if not here:
            problems.append(f"compose.yaml never expands {name}.")
            continue
        if not there:
            problems.append(f".env.example has no {name} line.")
            continue
        if here.group(1) != there.group(1).strip():
            problems.append(
                f"compose.yaml defaults {name} to {here.group(1)!r} and "
                f".env.example says {there.group(1).strip()!r}."
            )


def the_volume_is_above_pgdata(problems):
    """The PostgreSQL volume is mounted where 18 keeps its data.

    18 keeps data in `/var/lib/postgresql/18/docker`, so the volume belongs one
    level up. Mounting `/var/lib/postgresql/data` — which every guide written
    before 18 says — makes the container refuse to start.
    """
    compose = read("compose.yaml")
    if "pgdata:/var/lib/postgresql/data" in compose:
        problems.append(
            "compose.yaml mounts pgdata at /var/lib/postgresql/data. PostgreSQL 18 "
            "wants it one level up, at /var/lib/postgresql."
        )
    elif "pgdata:/var/lib/postgresql" not in compose:
        problems.append("compose.yaml does not mount pgdata at /var/lib/postgresql.")


def the_api_is_not_intercepted(problems):
    """nginx does not turn the Server's own refusals into a static page.

    The Server answers `503` with `Retry-After` and a `server.maintenance` body
    during a window, and the Client turns exactly that into its own maintenance
    page. `proxy_intercept_errors on` under the API location replaces it with
    HTML, hides the reason, and — because `/api/v1/health` must answer 200 at
    every maintenance level — breaks the thing the Client polls to learn it may
    come back.
    """
    # **Comments stripped first: this check reads directives, not prose.**
    # The `503` search below is a bare regex over the file, so a comment that
    # explains why 503 is *not* intercepted used to trip it -- `error_page`
    # written in one sentence and `503` in the next, with no `;` between them to
    # stop the match. A comment cannot configure nginx and must not fail a gate.
    config = re.sub(r"#[^\n]*", "", read("nginx/algojudge.conf"))

    api = re.search(r"location /api/v1/ \{(.*?)\n    \}", config, re.DOTALL)
    if api is None:
        problems.append("nginx/algojudge.conf has no `location /api/v1/` block.")
    elif "proxy_intercept_errors off" not in api.group(1):
        problems.append(
            "the /api/v1/ location does not say `proxy_intercept_errors off`. "
            "Intercepting there replaces the Server's maintenance refusal with a "
            "static page and breaks the Client's own maintenance handling."
        )

    if re.search(r"error_page[^;]*\b503\b", config):
        problems.append(
            "nginx/algojudge.conf intercepts 503. That status is the Server "
            "speaking — `server.maintenance` — and is not the proxy's to answer."
        )

    if not re.search(r"location /api/v1/admin \{\s*return 404", config):
        problems.append(
            "nginx/algojudge.conf does not refuse /api/v1/admin. The operator's "
            "surface answers only on the Server's own loopback interface and must "
            "not look reachable through the proxy."
        )


def the_health_path_is_versioned(problems):
    """Nothing points a health check at `/health`.

    Every installation serves the API at `/api/v1`, and the Server answers 404 at
    the bare root on purpose — so a check written against `/health` reports the
    installation down while it is serving perfectly.
    """
    for name in ("compose.yaml", "nginx/algojudge.conf", "scripts/lib/common.sh"):
        text = read(name)
        for number, line in enumerate(text.splitlines(), 1):
            if re.search(r"(?<!v1)/health\b", line) and "healthz" not in line:
                if "api/v1/health" in line or line.strip().startswith("#"):
                    continue
                problems.append(
                    f"{name}:{number} names /health rather than /api/v1/health. "
                    "The bare root answers 404 by design."
                )


def scripts_are_executable_and_shebanged(problems):
    """Every script has a shebang, LF endings, and the executable bit in Git.

    **The mode is asked of Git, not of the filesystem.** Windows does not carry
    one, so a script authored there is committed `100644` and a fresh clone on
    Linux answers `Permission denied` to the first command in the README.
    """
    import subprocess

    modes = {}
    try:
        listing = subprocess.run(
            ["git", "ls-files", "-s", "scripts"],
            cwd=ROOT, capture_output=True, text=True, check=True,
        ).stdout
        for line in listing.splitlines():
            mode, _, _, name = line.replace("\t", " ").split(None, 3)
            modes[name] = mode
    except (subprocess.CalledProcessError, FileNotFoundError, ValueError):
        modes = {}  # Not a checkout, or no git. The other two still apply.

    for script in sorted((ROOT / "scripts").rglob("*")):
        if script.suffix not in {".sh", ".py"}:
            continue
        relative = script.relative_to(ROOT).as_posix()

        raw = script.read_bytes()

        first = raw.decode("utf-8").splitlines()[0]
        if not first.startswith("#!"):
            problems.append(f"{relative} has no shebang.")

        # **Bytes, not `read_text(newline="")`.** That keyword arrived in Python
        # 3.13 and CI runs 3.12, where passing it raises.
        if b"\r" in raw:
            problems.append(
                f"{relative} has CRLF line endings. A shebang ending in \\r names "
                "a command that does not exist, and the error says neither the "
                "file nor the reason."
            )

        if modes.get(relative, "100755") != "100755":
            problems.append(
                f"{relative} is committed {modes[relative]}, not executable. A fresh "
                "clone answers 'Permission denied' to the first command in the "
                "README. Fix with: git update-index --chmod=+x " + relative
            )


CHECKS = (
    no_secret_committed,
    env_example_and_compose_agree,
    secrets_have_no_defaults,
    one_postgres_major,
    the_product_tags_agree,
    the_volume_is_above_pgdata,
    the_api_is_not_intercepted,
    the_health_path_is_versioned,
    scripts_are_executable_and_shebanged,
)


def main():
    argparse.ArgumentParser(description=__doc__).parse_args()

    problems = []
    for check in CHECKS:
        check(problems)

    for problem in problems:
        print(f"check-repository: {problem}", file=sys.stderr)

    if problems:
        print(
            f"check-repository: {len(problems)} problem(s).", file=sys.stderr
        )
        return 1

    print(f"check-repository: {len(CHECKS)} checks, nothing to report.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
