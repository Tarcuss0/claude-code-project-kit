"""Тесты scripts/deployed.py: временный git-репозиторий, скрипт копируется в его scripts/."""
import json
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

SOURCE = Path(__file__).resolve().parent.parent / "scripts" / "deployed.py"


def git(repo: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-c", "user.email=t@t", "-c", "user.name=t", *args],
        cwd=repo, check=True, capture_output=True, text=True,
    ).stdout.strip()


def commit(repo: Path, files: dict, message: str) -> str:
    for name, text in files.items():
        path = repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        git(repo, "add", name)
    git(repo, "commit", "-q", "-m", message)
    return git(repo, "rev-parse", "HEAD")


def write_marker(repo: Path, state: dict, bom: bool = False) -> None:
    path = repo / "deploy" / "deployed.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(state, ensure_ascii=False)
    path.write_bytes((b"\xef\xbb\xbf" if bom else b"") + text.encode("utf-8"))


def one(sha: str, dirty: bool = False) -> dict:
    return {"commit": sha, "commit_short": sha[:7], "release": "20260101-000000",
            "deployed_at": "2026-01-01T00:00:00+03:00", "dirty": dirty}


@pytest.fixture
def repo(tmp_path):
    subprocess.run(["git", "init", "-q", "-b", "main"], cwd=tmp_path, check=True)
    (tmp_path / "scripts").mkdir()
    shutil.copy(SOURCE, tmp_path / "scripts" / "deployed.py")
    return tmp_path


def run(repo: Path, *args: str):
    return subprocess.run(
        [sys.executable, str(repo / "scripts" / "deployed.py"), *args],
        cwd=repo, capture_output=True, text=True, encoding="utf-8",
    )


def history(repo: Path):
    c1 = commit(repo, {"a.txt": "1"}, "первый")
    c2 = commit(repo, {"a.txt": "2"}, "второй")
    c3 = commit(repo, {"a.txt": "3"}, "третий")
    c4 = commit(repo, {"a.txt": "4"}, "четвёртый")
    return c1, c2, c3, c4


def test_no_marker_says_so_and_exits_zero(repo):
    commit(repo, {"a.txt": "1"}, "первый")
    got = run(repo)
    assert got.returncode == 0
    assert "Маркер выкатки не найден" in got.stdout


def test_same_commit_counts_newer_commits(repo):
    c1, c2, c3, c4 = history(repo)
    write_marker(repo, {"backend": one(c2), "frontend": one(c2)})
    got = run(repo)
    assert got.returncode == 0
    assert "Не выкачено (2)" in got.stdout
    assert "третий" in got.stdout and "четвёртый" in got.stdout
    assert "второй" not in got.stdout.split("Не выкачено")[1]
    assert "на одном коммите" in got.stdout


def test_counts_from_the_lagging_artifact(repo):
    c1, c2, c3, c4 = history(repo)
    write_marker(repo, {"backend": one(c3), "frontend": one(c2)})
    got = run(repo)
    assert "Не выкачено (2)" in got.stdout
    assert "третий" in got.stdout
    assert "считаем от отставшего: frontend" in got.stdout


def test_any_number_of_artifacts_uses_the_oldest(repo):
    c1, c2, c3, c4 = history(repo)
    write_marker(repo, {"api": one(c4), "worker": one(c2), "web": one(c3)})
    got = run(repo)
    assert "Не выкачено (2)" in got.stdout
    assert "считаем от отставшего: worker" in got.stdout


def test_only_one_artifact_ever_deployed(repo):
    c1, c2, c3, c4 = history(repo)
    write_marker(repo, {"backend": one(c3)})
    got = run(repo)
    assert "Не выкачено (1)" in got.stdout
    assert "выкачен только один артефакт" in got.stdout


def test_marker_commit_is_not_counted(repo):
    c1, c2, c3, c4 = history(repo)
    write_marker(repo, {"backend": one(c4), "frontend": one(c4)})
    commit(repo, {"deploy/deployed.json": (repo / "deploy" / "deployed.json").read_text(encoding="utf-8")},
           "Выкатка: маркер")
    got = run(repo)
    assert "Не выкачено: ничего" in got.stdout


def test_commit_with_marker_and_other_file_is_counted(repo):
    c1, c2, c3, c4 = history(repo)
    write_marker(repo, {"backend": one(c4)})
    text = (repo / "deploy" / "deployed.json").read_text(encoding="utf-8")
    commit(repo, {"deploy/deployed.json": text, "work.txt": "чья-то работа"}, "Выкатка: маркер (но с работой)")
    got = run(repo)
    assert "Не выкачено (1)" in got.stdout
    assert "маркер (но с работой)" in got.stdout


def test_marker_with_bom_is_readable(repo):
    c1, c2, c3, c4 = history(repo)
    write_marker(repo, {"backend": one(c4)}, bom=True)
    got = run(repo)
    assert got.returncode == 0, got.stdout + got.stderr
    assert "backend" in got.stdout


def test_broken_marker_exits_one(repo):
    commit(repo, {"a.txt": "1"}, "первый")
    (repo / "deploy").mkdir()
    (repo / "deploy" / "deployed.json").write_text("{не json", encoding="utf-8")
    got = run(repo)
    assert got.returncode == 1
    assert "не читается" in got.stdout


def test_dirty_artifact_is_called_out(repo):
    c1, c2, c3, c4 = history(repo)
    write_marker(repo, {"backend": one(c4, dirty=True)})
    got = run(repo)
    assert "ГРЯЗНОЕ ДЕРЕВО" in got.stdout
    assert "собран из грязного дерева" in got.stdout


def test_short_prints_one_line(repo):
    c1, c2, c3, c4 = history(repo)
    write_marker(repo, {"backend": one(c3), "frontend": one(c2)})
    got = run(repo, "--short")
    lines = got.stdout.strip().splitlines()
    assert len(lines) == 1
    assert lines[0] == f"прод: {c2[:7]}, невыкачено 2"


def test_history_key_is_not_an_artifact(repo):
    c1, c2, c3, c4 = history(repo)
    write_marker(repo, {"backend": one(c4),
                        "history": [{"at": "x", "components": ["backend"], "commit_short": "abc"}]})
    got = run(repo)
    assert got.returncode == 0
    assert "history" not in got.stdout
