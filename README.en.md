# claude-code-project-kit

A starter kit for projects built with several parallel Claude Code sessions. It holds the working rules I carry from project to project: how sessions split a codebase, how state is handed over, how tests stay fast, how backups are made and verified, and how deploys are done by hand.

Russian is the main language of this repository. Full instructions and the methodology: [README.md](README.md) and [docs/METHODOLOGY.md](docs/METHODOLOGY.md).

## The ideas

- **Sessions own zones.** 3–4 sessions, each with its own directories, tests and test-database suffix. One session owns the core; the others use only its public interface, and a boundary test enforces it.
- **State lives in files.** Each session keeps a `HANDOVER-X.md` in the repo, so work survives context compaction and lost sessions. See [examples/](examples/).
- **Diagnose first, code second.** Sessions explain the plan and wait for approval before writing code. Every report ends with what was not verified.
- **Sessions test only what they changed.** The full suite is never part of the deploy; it runs when the owner decides (audits, big refactors). Failing tests are tracked in per-session files.
- **A backup that was never restored is not a backup.** Daily dumps on the server with a freshness marker, a copy on the owner's PC every two hours, a `git bundle` of the repository, and a restore check before handover. The PC side only trusts what it verified by checksum, and raises an alarm when the server stops producing fresh snapshots instead of reporting success on an old one.
- **Humans deploy.** Sessions never push or deploy. `deploy.ps1` refuses a dirty or unpushed tree, runs the guards and the secrets scan, builds each artifact locally in a fixed order (schema before code, backend before frontend), ships it, and a server-side receiver switches a `current` symlink, restarts, waits for `/health` and rolls back on its own if it fails. A marker file records what the server actually accepted.
- **Every found class of mistake goes into a shared list** in `CLAUDE.md`, the same shift it was found.

## What is inside

| Path | Purpose |
|------|---------|
| `CLAUDE.md` | Rules read automatically by Claude Code in every session |
| `docs/METHODOLOGY.md` | The full method (Russian) |
| `docs/HANDOVER-TEMPLATE.md`, `docs/TESTS-FAILING-TEMPLATE.md` | Per-session templates |
| `docs/KNOWN-GAPS.md` | What is verified, what is not, and how to check each item |
| `examples/` | Filled-in examples for a fictional project |
| `scripts/db-backup.sh` | PostgreSQL snapshots (`<stamp>/database.dump` + `OK`), rotation, readability check, marker file (server, cron) |
| `scripts/dburl.py` | `DATABASE_URL` parser that survives a `%` in the password |
| `scripts/pull-backup.ps1` | Pull the newest snapshot to a PC: one ssh call lists SHA256 sums, download to a staging dir, per-file verification, atomic move, retention with a minimum-copies floor, stale-snapshot alarm (exit code 2) |
| `scripts/bundle-repos.ps1`, `install-backup-task.ps1`, `scripts/lib-backup.ps1` | Verified `git bundle` of repositories, Windows scheduled task, shared PowerShell functions |
| `scripts/deploy.ps1`, `scripts/lib-deploy.ps1`, `scripts/version-stamp.ps1` | Artifact-based deploy: tree checks, build, upload, receive, version check against the server, marker, manual rollback, `-WhatIf`, `-MarkOnly` |
| `scripts/checks.py`, `scripts/guards/` | Runs the secrets scan and every project guard (`guards/*.py`) in one go; `_template.py` documents the contract |
| `scripts/deployed.py` | What is on production now and which commits have not gone out, from `deploy/deployed.json` |
| `server/release.sh`, `server/release.env.example` | Server-side receiver: release directories, atomic symlink switch, restart, health wait, automatic rollback, pruning |
| `docs/DEPLOY.md` | Deploy order, additive-migration rule, health convention (`/healthz` liveness, `/health` with DB check), first-time server setup, rollback (Russian) |
| `scripts/check_secrets.py` | Secret and forbidden-file scan before commit and deploy |
| `tests/` | Tests for the scripts; CI runs shellcheck, pytest, PowerShell unit tests, an end-to-end deploy run against a simulated server, a secrets scan and a PowerShell syntax check |

## Quick start

1. Copy the contents into your project.
2. Copy `scripts/project.conf.example` to `scripts/project.conf` and fill it in (it is git-ignored).
3. Follow the steps in [README.md](README.md): server backup, PC backup, restore check.

## Status

The scripts are extracted from projects I run in production, then generalized. `dburl.py`, `check_secrets.py` and the PowerShell library have tests (mutation-checked), `db-backup.sh` is shellchecked in CI, the PowerShell scripts are syntax-checked there. The pull and backup scripts were also run end to end against a simulated server (fake `docker`, `ssh`, `scp`) covering success, re-run, corrupted copy, corrupted transfer, missing `OK`, stale snapshot, missing key. The deploy was run end to end the same way (fake `ssh`/`scp`, real `release.sh`, git, tar and curl): happy path with two artifacts, `-WhatIf`, dirty tree, unpushed tree, red guard, build failure, upload failure, a second artifact that fails its health check and is rolled back by the server, manual rollback, `-MarkOnly`; the test is mutation-checked. None of it has run against a real server, Windows PowerShell 5.1 or Windows Task Scheduler yet: dry-run them on your own setup (`-WhatIf`) before you rely on them. The full list of what is and is not verified is in [docs/KNOWN-GAPS.md](docs/KNOWN-GAPS.md).

MIT licensed.
