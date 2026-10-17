# -*- coding: utf-8 -*-
"""Сторож scripts/guards/20-docs-sync.py на временных репозиториях."""
import json
import pytest
import shutil
import subprocess
import sys
from pathlib import Path

KIT = Path(__file__).resolve().parent.parent
GUARD = "scripts/guards/20-docs-sync.py"


def git(repo: Path, *args: str) -> str:
    done = subprocess.run(
        ["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", *args],
        cwd=repo, capture_output=True, text=True, encoding="utf-8", check=True,
    )
    return done.stdout.strip()


def commit(repo: Path, files: dict[str, str], message: str = "правка") -> str:
    for name, text in files.items():
        path = repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", message)
    return git(repo, "rev-parse", "HEAD")


def write_marker(repo: Path, **commits: str) -> None:
    state = {name: {"commit": sha, "commit_short": sha[:7]} for name, sha in commits.items()}
    marker = repo / "deploy" / "deployed.json"
    marker.parent.mkdir(exist_ok=True)
    marker.write_text(json.dumps(state), encoding="utf-8")


def run_guard(repo: Path) -> tuple[int, str]:
    done = subprocess.run(
        [sys.executable, str(repo / GUARD)], cwd=repo, capture_output=True,
        text=True, encoding="utf-8",
    )
    return done.returncode, done.stdout + done.stderr


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    git(tmp_path, "init", "-q", "-b", "main")
    (tmp_path / "scripts" / "guards").mkdir(parents=True)
    shutil.copy(KIT / GUARD, tmp_path / GUARD)
    shutil.copy(KIT / "scripts" / "deployed.py", tmp_path / "scripts" / "deployed.py")
    commit(tmp_path, {"app.py": "1", "docs/ARCHITECTURE.md": "v1", "migrations/0001.sql": "a"}, "старт")
    return tmp_path


def test_no_marker_is_skipped_with_a_note(repo):
    code, out = run_guard(repo)
    assert code == 0
    assert "выкаток" in out


def test_unrelated_change_passes(repo):
    deployed = git(repo, "rev-parse", "HEAD")
    write_marker(repo, backend=deployed)
    commit(repo, {"app.py": "2"})
    code, out = run_guard(repo)
    assert code == 0, out
    assert "не менялись" in out


def test_migration_without_doc_fails_and_names_the_file(repo):
    write_marker(repo, backend=git(repo, "rev-parse", "HEAD"))
    commit(repo, {"migrations/0002_add_column.sql": "b"})
    code, out = run_guard(repo)
    assert code == 1
    assert "ПЛОХО" in out
    assert "migrations/0002_add_column.sql" in out
    assert "модель данных" in out


def test_migration_with_doc_change_in_a_later_commit_passes(repo):
    write_marker(repo, backend=git(repo, "rev-parse", "HEAD"))
    commit(repo, {"migrations/0002.sql": "b"})
    commit(repo, {"docs/ARCHITECTURE.md": "v2"})
    code, out = run_guard(repo)
    assert code == 0, out
    assert "правился" in out


def test_explicit_no_change_trailer_passes(repo):
    write_marker(repo, backend=git(repo, "rev-parse", "HEAD"))
    commit(repo, {"migrations/0002.sql": "b"}, "индекс\n\nСессия: Б\nАрхитектура: без изменений")
    code, out = run_guard(repo)
    assert code == 0, out
    assert "заявлено" in out


def test_trailer_older_than_last_deploy_does_not_count(repo):
    commit(repo, {"app.py": "2"}, "старое\n\nАрхитектура: без изменений")
    write_marker(repo, backend=git(repo, "rev-parse", "HEAD"))
    commit(repo, {"migrations/0002.sql": "b"})
    code, _ = run_guard(repo)
    assert code == 1


def test_dependency_manifest_counts(repo):
    write_marker(repo, backend=git(repo, "rev-parse", "HEAD"))
    commit(repo, {"backend/requirements.txt": "fastapi"})
    code, out = run_guard(repo)
    assert code == 1
    assert "стек и зависимости" in out
    assert "backend/requirements.txt" in out


def test_missing_doc_says_to_create_it(repo):
    git(repo, "rm", "-q", "docs/ARCHITECTURE.md")
    git(repo, "commit", "-q", "-m", "убрали")
    write_marker(repo, backend=git(repo, "rev-parse", "HEAD"))
    commit(repo, {"migrations/0002.sql": "b"})
    code, out = run_guard(repo)
    assert code == 1
    assert "ARCHITECTURE-TEMPLATE" in out


def test_window_starts_from_the_lagging_artifact(repo):
    front = git(repo, "rev-parse", "HEAD")
    commit(repo, {"migrations/0002.sql": "b"})
    back = git(repo, "rev-parse", "HEAD")
    write_marker(repo, backend=back, frontend=front)
    code, out = run_guard(repo)
    assert code == 1, "миграция после коммита фронта ещё не выкачена целиком"
    assert "migrations/0002.sql" in out


def test_unreadable_marker_fails_loudly(repo):
    marker = repo / "deploy" / "deployed.json"
    marker.parent.mkdir()
    marker.write_text("{не json", encoding="utf-8")
    code, out = run_guard(repo)
    assert code == 1
    assert "ПЛОХО" in out


def test_unknown_deployed_commit_fails_loudly(repo):
    write_marker(repo, backend="0" * 40)
    code, out = run_guard(repo)
    assert code == 1
    assert "ПЛОХО" in out


def test_marker_only_commit_is_not_a_change(repo):
    write_marker(repo, backend=git(repo, "rev-parse", "HEAD"))
    commit(repo, {"deploy/deployed.json": json.dumps({"backend": {"commit": git(repo, "rev-parse", "HEAD")}})}, "маркер")
    code, out = run_guard(repo)
    assert code == 0, out
