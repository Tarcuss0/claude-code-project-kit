# -*- coding: utf-8 -*-
"""Тесты scripts/commit.py на настоящем git во временном репозитории.

Сценарии взяты из живого проекта: чужие подготовленные пути, вчерашний индекс,
гонка двух коммитов. Гонка моделируется хуком pre-commit: он срабатывает между
сборкой дерева и записью ссылки и успевает вписать «чужой» коммит."""
import os
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "commit.py"


def git(repo: Path, *args: str) -> str:
    done = subprocess.run(["git", *args], cwd=repo, capture_output=True, text=True, encoding="utf-8")
    assert done.returncode == 0, done.stderr
    return done.stdout.strip()


def commit_py(repo: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args], cwd=repo,
        capture_output=True, text=True, encoding="utf-8", errors="replace",
    )


@pytest.fixture
def repo(tmp_path: Path, monkeypatch) -> Path:
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", os.devnull)
    for key, value in {"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
                       "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}.items():
        monkeypatch.setenv(key, value)
    git(tmp_path, "init", "-q", "-b", "main")
    (tmp_path / "a").mkdir()
    (tmp_path / "b").mkdir()
    (tmp_path / "docs").mkdir()
    (tmp_path / "a" / "x.py").write_text("a1\n", encoding="utf-8")
    (tmp_path / "b" / "y.py").write_text("b1\n", encoding="utf-8")
    git(tmp_path, "add", ".")
    git(tmp_path, "commit", "-q", "-m", "init")
    return tmp_path


def files_in(repo: Path, rev: str = "HEAD") -> list:
    return git(repo, "diff-tree", "--no-commit-id", "--name-only", "-r", rev).split()


def test_commits_only_named_path_and_leaves_neighbours_staged(repo):
    (repo / "a" / "x.py").write_text("a2\n", encoding="utf-8")
    (repo / "b" / "y.py").write_text("b2\n", encoding="utf-8")
    git(repo, "add", "b/y.py")  # соседняя сессия подготовила свой файл
    got = commit_py(repo, "--session", "А", "-m", "правка a", "a/x.py")
    assert got.returncode == 0, got.stdout
    assert files_in(repo) == ["a/x.py"]
    assert git(repo, "diff", "--cached", "--name-only") == "b/y.py"
    assert "Сессия: А" in git(repo, "log", "-1", "--format=%B")
    assert "сверка состава" in got.stdout


def test_takes_todays_file_not_yesterdays_index(repo):
    (repo / "a" / "x.py").write_text("вчера\n", encoding="utf-8")
    git(repo, "add", "a/x.py")
    (repo / "a" / "x.py").write_text("сегодня\n", encoding="utf-8")
    got = commit_py(repo, "--session", "А", "-m", "правка", "a/x.py")
    assert got.returncode == 0, got.stdout
    assert git(repo, "show", "HEAD:a/x.py") == "сегодня"
    assert git(repo, "diff", "--cached", "--name-only") == ""


@pytest.mark.parametrize("arg,word", [("a", "каталог"), ("a/*.py", "маски"), ("a/none.py", "нет ни на диске")],
                         ids=["dir", "glob", "missing"])
def test_refuses_vague_paths(repo, arg, word):
    (repo / "a" / "x.py").write_text("a2\n", encoding="utf-8")
    got = commit_py(repo, "--session", "А", "-m", "m", arg)
    assert got.returncode == 1
    assert word in got.stdout
    assert git(repo, "log", "--oneline").count("\n") == 0


def test_refuses_path_outside_zone(repo):
    (repo / "docs" / "HANDOVER-А.md").write_text(
        "## Зона\n\n- Каталоги и файлы, которыми владеет эта сессия: `a/`, docs/HANDOVER-А.md\n",
        encoding="utf-8")
    (repo / "b" / "y.py").write_text("b2\n", encoding="utf-8")
    got = commit_py(repo, "--session", "А", "-m", "m", "b/y.py")
    assert got.returncode == 1
    assert "вне зоны" in got.stdout and "b/y.py" in got.stdout
    (repo / "a" / "x.py").write_text("a2\n", encoding="utf-8")
    assert commit_py(repo, "--session", "А", "-m", "m", "a/x.py").returncode == 0


def test_unfilled_zone_is_said_not_silent(repo):
    (repo / "a" / "x.py").write_text("a2\n", encoding="utf-8")
    got = commit_py(repo, "--session", "Б", "-m", "m", "a/x.py")
    assert got.returncode == 0
    assert "НЕ СОСТОЯЛАСЬ сверка зоны" in got.stdout


def test_refuses_when_named_paths_have_no_changes(repo):
    got = commit_py(repo, "--session", "А", "-m", "m", "a/x.py")
    assert got.returncode == 1
    assert "нет изменений" in got.stdout


def test_new_file_is_committed_without_staging_content_for_others(repo):
    (repo / "a" / "new.py").write_text("новый\n", encoding="utf-8")
    (repo / "b" / "y.py").write_text("b2\n", encoding="utf-8")
    got = commit_py(repo, "--session", "А", "-m", "новый файл", "a/new.py")
    assert got.returncode == 0, got.stdout
    assert files_in(repo) == ["a/new.py"]
    assert git(repo, "show", "HEAD:a/new.py") == "новый"
    assert git(repo, "diff", "--cached", "--name-only") == ""  # в общем индексе ничего не осталось


PEEK_HOOK = """#!/bin/sh
COMMON=$(git rev-parse --git-common-dir)
GIT_INDEX_FILE="$COMMON/index" git diff --cached --name-only > "$COMMON/peek"
"""


@pytest.mark.skipif(sys.platform == "win32", reason="хук на sh")
def test_new_file_content_never_sits_in_shared_index(repo):
    # пока идёт коммит, сосед может сделать обычный git commit: содержимое нового файла
    # не должно лежать в общем индексе даже на это время
    hook = repo / ".git" / "hooks" / "pre-commit"
    hook.write_text(PEEK_HOOK, encoding="utf-8")
    hook.chmod(0o755)
    (repo / "a" / "new.py").write_text("новый\n", encoding="utf-8")
    assert commit_py(repo, "--session", "А", "-m", "m", "a/new.py").returncode == 0
    assert (repo / ".git" / "peek").read_text(encoding="utf-8").strip() == ""


def test_deleted_tracked_file_is_committed(repo):
    (repo / "a" / "x.py").unlink()
    got = commit_py(repo, "--session", "А", "-m", "удалил", "a/x.py")
    assert got.returncode == 0, got.stdout
    assert files_in(repo) == ["a/x.py"]


RACE_HOOK = """#!/bin/sh
MARK="$(git rev-parse --git-common-dir)/race-done"
[ -f "$MARK" ] && exit 0
touch "$MARK"
unset GIT_INDEX_FILE
T=$(mktemp); H=$(git rev-parse HEAD)
GIT_INDEX_FILE=$T git read-tree $H
B=$(echo b-сосед | git hash-object -w --stdin)
GIT_INDEX_FILE=$T git update-index --cacheinfo 100644,$B,b/y.py
TR=$(GIT_INDEX_FILE=$T git write-tree); C=$(echo сосед | git commit-tree $TR -p $H)
git update-ref HEAD $C $H
rm -f $T
"""


@pytest.mark.skipif(sys.platform == "win32", reason="хук на sh")
def test_race_with_neighbour_retries_and_keeps_neighbours_commit(repo):
    hook = repo / ".git" / "hooks" / "pre-commit"
    hook.write_text(RACE_HOOK, encoding="utf-8")
    hook.chmod(0o755)
    (repo / "a" / "x.py").write_text("a2\n", encoding="utf-8")
    got = commit_py(repo, "--session", "А", "-m", "моя правка", "a/x.py")
    assert got.returncode == 0, got.stdout
    assert "гонка с другой сессией" in got.stdout
    assert git(repo, "show", "HEAD:b/y.py") == "b-сосед"  # чужой коммит не откатан
    assert git(repo, "show", "HEAD:a/x.py") == "a2"
    assert git(repo, "log", "-2", "--format=%s").split("\n") == ["моя правка", "сосед"]
    assert files_in(repo) == ["a/x.py"]


EXTRA_HOOK = """#!/bin/sh
echo лишнее > a/extra.py
git add a/extra.py
"""


@pytest.mark.skipif(sys.platform == "win32", reason="хук на sh")
def test_composition_check_catches_extra_path(repo):
    # хук подсовывает в коммит лишний файл: сверка после записи обязана это назвать
    hook = repo / ".git" / "hooks" / "pre-commit"
    hook.write_text(EXTRA_HOOK, encoding="utf-8")
    hook.chmod(0o755)
    (repo / "a" / "x.py").write_text("a2\n", encoding="utf-8")
    got = commit_py(repo, "--session", "А", "-m", "m", "a/x.py")
    assert got.returncode == 1, got.stdout
    assert "ПЛОХО: в коммит попали чужие пути: a/extra.py" in got.stdout
