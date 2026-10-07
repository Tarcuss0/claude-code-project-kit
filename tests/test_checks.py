"""Тесты scripts/checks.py: скрипт копируется во временный каталог со своими сторожами."""
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

SOURCE = Path(__file__).resolve().parent.parent / "scripts" / "checks.py"


@pytest.fixture
def tree(tmp_path):
    (tmp_path / "scripts" / "guards").mkdir(parents=True)
    shutil.copy(SOURCE, tmp_path / "scripts" / "checks.py")
    return tmp_path


def guard(tree: Path, name: str, body: str, header: str = "") -> None:
    (tree / "scripts" / "guards" / name).write_text(header + body, encoding="utf-8")


def run(tree: Path, *args: str):
    return subprocess.run(
        [sys.executable, str(tree / "scripts" / "checks.py"), *args],
        cwd=tree, capture_output=True, text=True, encoding="utf-8",
    )


def test_no_guards_is_not_a_failure(tree):
    got = run(tree)
    assert got.returncode == 0
    assert "Сторожей нет" in got.stdout


def test_passing_guards_report_ok_with_about(tree):
    guard(tree, "10-a.py", "print('fine')\n", "# about: стережёт A\n")
    got = run(tree)
    assert got.returncode == 0
    assert "10-a.py" in got.stdout and "стережёт A" in got.stdout
    assert "Сторожа дерева прошли" in got.stdout


def test_failing_guard_fails_run_and_shows_blamed_lines_not_tail(tree):
    body = (
        "print('ПЛОХО: файл x нарушает правило')\n"
        + "".join(f"print('ок строка {i}')\n" for i in range(20))
        + "raise SystemExit(1)\n"
    )
    guard(tree, "10-bad.py", body)
    got = run(tree)
    assert got.returncode == 1
    assert "Не прошли: 10-bad.py" in got.stdout
    assert "ПЛОХО: файл x нарушает правило" in got.stdout.split("Не прошли")[0]


def test_failure_without_blamed_lines_shows_tail(tree):
    guard(tree, "10-quiet.py", "print('вот причина')\nraise SystemExit(2)\n")
    got = run(tree)
    assert got.returncode == 1
    assert "вот причина" in got.stdout


def test_files_starting_with_underscore_are_not_run(tree):
    guard(tree, "_template.py", "raise SystemExit(1)\n")
    guard(tree, "10-a.py", "print('ok')\n")
    got = run(tree)
    assert got.returncode == 0
    assert "_template" not in got.stdout


def test_quick_skips_needs_db_guards(tree):
    guard(tree, "10-db.py", "raise SystemExit(1)\n", "# needs-db\n# about: схема\n")
    guard(tree, "20-fast.py", "print('ok')\n")
    full = run(tree)
    assert full.returncode == 1
    quick = run(tree, "--quick")
    assert quick.returncode == 0
    assert "пропуск" in quick.stdout and "10-db.py" in quick.stdout


def test_guards_run_in_filename_order(tree):
    guard(tree, "20-second.py", "print('ok')\n")
    guard(tree, "10-first.py", "print('ok')\n")
    got = run(tree)
    assert got.stdout.index("10-first.py") < got.stdout.index("20-second.py")


def test_cwd_header_changes_working_directory(tree):
    (tree / "sub").mkdir()
    guard(tree, "10-cwd.py",
          "import os, sys\nsys.exit(0 if os.getcwd().endswith('sub') else 1)\n",
          "# cwd: sub\n")
    assert run(tree).returncode == 0


def test_check_secrets_runs_first_when_present(tree):
    (tree / "scripts" / "check_secrets.py").write_text("print('ПЛОХО: секрет')\nraise SystemExit(1)\n")
    guard(tree, "10-a.py", "print('ok')\n")
    got = run(tree)
    assert got.returncode == 1
    assert got.stdout.index("check_secrets.py") < got.stdout.index("10-a.py")
    assert "Не прошли: check_secrets.py" in got.stdout


def test_header_is_only_read_from_first_lines(tree):
    body = "\n" * 20 + "# needs-db\nprint('ok')\nraise SystemExit(1)\n"
    guard(tree, "10-late.py", body)
    assert run(tree, "--quick").returncode == 1
