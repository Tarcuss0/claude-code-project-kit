# -*- coding: utf-8 -*-
"""Тесты scripts/run-lock.py: скрипт копируется во временное дерево, замки лежат в его .locks/.
Держатель замка запускается настоящим отдельным процессом, а не подменой."""
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

import pytest

SOURCE = Path(__file__).resolve().parent.parent / "scripts" / "run-lock.py"
pytestmark = pytest.mark.skipif(os.name == "nt", reason="сценарии с сигналами написаны для POSIX")


@pytest.fixture
def tree(tmp_path):
    (tmp_path / "scripts").mkdir()
    shutil.copy(SOURCE, tmp_path / "scripts" / "run-lock.py")
    return tmp_path


def lock_cmd(tree: Path, resource: str, *cmd: str, session: str = "А", extra=()) -> list:
    return [sys.executable, str(tree / "scripts" / "run-lock.py"), resource, "--session", session,
            *extra, "--", *cmd]


def run(tree, resource, *cmd, **kw) -> subprocess.CompletedProcess:
    return subprocess.run(lock_cmd(tree, resource, *cmd, **kw), cwd=tree, capture_output=True,
                          text=True, encoding="utf-8", timeout=60)


def start_holder(tree, resource, seconds: float, session: str = "Б") -> subprocess.Popen:
    proc = subprocess.Popen(
        lock_cmd(tree, resource, sys.executable, "-c", f"import time; time.sleep({seconds})", session=session),
        cwd=tree, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding="utf-8",
        start_new_session=True,
    )
    holder = tree / ".locks" / f"{resource}.holder.json"
    for _ in range(100):
        if holder.exists():
            return proc
        time.sleep(0.05)
    proc.kill()
    raise AssertionError("держатель не взял замок")


def py(code: str) -> tuple:
    return (sys.executable, "-c", code)


def test_free_resource_runs_command_and_passes_exit_code(tree):
    got = run(tree, "db_a", *py("raise SystemExit(7)"))
    assert got.returncode == 7, got.stdout
    assert "взят" in got.stdout and "снят" in got.stdout
    assert not (tree / ".locks" / "db_a.holder.json").exists()
    assert (tree / ".locks" / "db_a.lock").exists()  # файл замка не удаляется никогда


def test_busy_resource_refuses_and_names_holder(tree):
    holder = start_holder(tree, "db_a", 5, session="Б")
    try:
        got = run(tree, "db_a", *py("open('ran', 'w')"))
        assert got.returncode == 3, got.stdout
        assert "НЕ НАЧАТ" in got.stdout and "сессия Б" in got.stdout and "pid" in got.stdout
        assert not (tree / "ran").exists()  # команда не запускалась
    finally:
        os.killpg(holder.pid, signal.SIGKILL)
        holder.wait()


def test_different_resources_do_not_block_each_other(tree):
    holder = start_holder(tree, "db_a", 5)
    try:
        assert run(tree, "db_b", *py("pass")).returncode == 0
    finally:
        os.killpg(holder.pid, signal.SIGKILL)
        holder.wait()


def test_wait_gets_the_lock_after_holder_finishes(tree):
    holder = start_holder(tree, "db_a", 1.5)
    got = run(tree, "db_a", *py("open('ran', 'w')"), extra=("--wait", "20"))
    holder.wait()
    assert got.returncode == 0, got.stdout
    assert "жду" in got.stdout
    assert (tree / "ran").exists()


def test_lock_is_released_when_holder_dies(tree):
    holder = start_holder(tree, "db_a", 30)
    os.killpg(holder.pid, signal.SIGKILL)  # погибли и run-lock, и его команда
    holder.wait()
    got = run(tree, "db_a", *py("pass"))
    assert got.returncode == 0, got.stdout  # никаких «занято» после смерти держателя


def test_lock_survives_killed_run_lock_while_command_still_runs(tree):
    # убили только run-lock, прогон продолжается: ресурс должен остаться занятым
    holder = start_holder(tree, "db_a", 3)
    os.kill(holder.pid, signal.SIGKILL)
    holder.wait()
    busy = run(tree, "db_a", *py("pass"))
    assert busy.returncode == 3, busy.stdout
    time.sleep(3.5)  # команда-сирота закончила
    free = run(tree, "db_a", *py("pass"))
    assert free.returncode == 0, free.stdout


@pytest.mark.parametrize("args,word", [
    (["bad/name", "--", "true"], "имя ресурса"),
    (["db_a"], "нужен «--»"),
    (["db_a", "--"], "нет команды"),
], ids=["bad-name", "no-separator", "no-command"])
def test_refuses_bad_calls(tree, args, word):
    got = subprocess.run([sys.executable, str(tree / "scripts" / "run-lock.py"), *args], cwd=tree,
                         capture_output=True, text=True, encoding="utf-8")
    assert got.returncode == 3
    assert word in got.stdout
