# -*- coding: utf-8 -*-
"""Подлог на сам разбор исхода: скармливаем ему настоящий вывод pytest каждого вида
и проверяем, что виды называются по-разному. Образцы не пишутся руками: каждый
получается живым прогоном pytest во временной папке, иначе тест сверял бы разбор
с нашим же представлением о выводе."""
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "outcome.py"
sys.path.insert(0, str(ROOT / "scripts"))
import outcome  # noqa: E402

GREEN, NOT_PASSED, NOT_HELD, NOT_REACHED, REFUSED, PROBE_FAILED = 0, 1, 2, 3, 4, 5


def run_outcome(tmp_path: Path, files: dict, *extra: str) -> subprocess.CompletedProcess:
    for name, body in files.items():
        (tmp_path / name).write_text(body, encoding="utf-8")
    return subprocess.run(
        [sys.executable, str(SCRIPT), "run", *extra, "--", "-p", "no:cacheprovider", str(tmp_path)],
        cwd=tmp_path, capture_output=True, text=True, encoding="utf-8", errors="replace",
    )


def raw_pytest(tmp_path: Path, files: dict, *args: str) -> str:
    for name, body in files.items():
        (tmp_path / name).write_text(body, encoding="utf-8")
    done = subprocess.run(
        [sys.executable, "-m", "pytest", "-p", "no:cacheprovider", *args, str(tmp_path)],
        cwd=tmp_path, capture_output=True, text=True, encoding="utf-8", errors="replace",
    )
    return done.stdout + done.stderr


PASS = "def test_ok():\n    assert True\n"
FAIL = "def test_bad():\n    assert 1 == 2\n"
ERROR = ("import pytest\n@pytest.fixture\ndef db():\n    raise RuntimeError('нет базы')\n"
         "def test_needs_db(db):\n    assert True\n")
SKIP = "import pytest\ndef test_env():\n    pytest.skip('нет переменной')\n"
MODULE_SKIP = ("import pytest\npytest.skip('весь файл: нет окружения', allow_module_level=True)\n"
               "def test_never():\n    assert True\n")
XFAIL = "import pytest\n@pytest.mark.xfail(reason='known')\ndef test_known():\n    assert False\n"
XPASS = "import pytest\n@pytest.mark.xfail(reason='known')\ndef test_fixed():\n    assert True\n"
BROKEN_IMPORT = "import nonexistent_module_xyz\ndef test_x():\n    assert True\n"


def test_all_passed_is_green(tmp_path):
    got = run_outcome(tmp_path, {"test_a.py": PASS})
    assert got.returncode == GREEN, got.stdout
    assert "Исход: ЗЕЛЁНЫЙ" in got.stdout


def test_failed_is_not_passed(tmp_path):
    got = run_outcome(tmp_path, {"test_a.py": PASS, "test_b.py": FAIL})
    assert got.returncode == NOT_PASSED, got.stdout
    assert "Исход: НЕ ПРОШЛА" in got.stdout
    assert "test_b.py::test_bad" in got.stdout


def test_setup_error_is_not_held_not_green(tmp_path):
    # «12 прошли, 2 ошибки» назвали зелёным: ошибка установки это несостоявшаяся мера
    got = run_outcome(tmp_path, {"test_a.py": PASS, "test_db.py": ERROR})
    assert got.returncode == NOT_HELD, got.stdout
    assert "Исход: НЕ СОСТОЯЛАСЬ" in got.stdout
    assert "ошибка установки" in got.stdout


@pytest.mark.parametrize("body", [SKIP, MODULE_SKIP, XFAIL, XPASS], ids=["skip", "module-skip", "xfail", "xpass"])
def test_skip_and_xfail_kinds_are_not_held(tmp_path, body):
    got = run_outcome(tmp_path, {"test_a.py": PASS, "test_b.py": body})
    assert got.returncode == NOT_HELD, got.stdout
    assert "Исход: НЕ СОСТОЯЛАСЬ" in got.stdout


def test_failed_and_errors_together_report_both(tmp_path):
    got = run_outcome(tmp_path, {"test_b.py": FAIL, "test_db.py": ERROR})
    assert got.returncode == NOT_PASSED, got.stdout
    assert "не прошли 1, не состоялись 1" in got.stdout


def test_collection_error_did_not_reach(tmp_path):
    got = run_outcome(tmp_path, {"test_a.py": PASS, "test_broken.py": BROKEN_IMPORT})
    assert got.returncode == NOT_REACHED, got.stdout
    assert "ошибка сбора" in got.stdout


def test_no_tests_did_not_reach(tmp_path):
    got = run_outcome(tmp_path, {"helper.py": "X = 1\n"})
    assert got.returncode == NOT_REACHED, got.stdout
    assert "не собрано ни одного теста" in got.stdout


def test_exit_code_of_pytest_is_not_evidence(tmp_path):
    # conftest ставит единицу при нуле упавших: исход читается по строкам тестов
    conftest = "def pytest_sessionfinish(session, exitstatus):\n    session.exitstatus = 1\n"
    got = run_outcome(tmp_path, {"conftest.py": conftest, "test_a.py": PASS})
    assert "код выхода pytest 1" in got.stdout
    assert got.returncode == GREEN, got.stdout


def test_stop_after_first_failure_is_said(tmp_path):
    got = run_outcome(tmp_path, {"test_a.py": FAIL, "test_b.py": PASS}, )
    assert got.returncode == NOT_PASSED
    stopped = subprocess.run(
        [sys.executable, str(SCRIPT), "run", "--", "-x", "-p", "no:cacheprovider", str(tmp_path)],
        cwd=tmp_path, capture_output=True, text=True, encoding="utf-8", errors="replace",
    )
    assert stopped.returncode == NOT_PASSED, stopped.stdout
    assert "остальные меры не запускались" in stopped.stdout


def test_output_without_per_test_lines_is_refused(tmp_path):
    text = raw_pytest(tmp_path, {"test_a.py": PASS, "test_db.py": ERROR}, "-q")
    code, lines = outcome.verdict(outcome.parse(text))
    assert code == REFUSED, lines
    assert "-rA" in lines[0]


def test_truncated_output_did_not_reach(tmp_path):
    text = raw_pytest(tmp_path, {"test_a.py": PASS}, "-rA")
    cut = "\n".join(line for line in text.splitlines() if " in " not in line or "passed" not in line)
    code, lines = outcome.verdict(outcome.parse(cut))
    assert code == NOT_REACHED, lines


def test_unknown_summary_kind_is_refused():
    text = "PASSED t.py::test_a\n==== 1 passed, 1 rerun in 0.10s ====\n"
    code, lines = outcome.verdict(outcome.parse(text))
    assert code == REFUSED
    assert "rerun" in lines[0]


def test_probe_red_only_on_failed(tmp_path):
    files = {"test_a.py": PASS, "test_b.py": FAIL, "test_db.py": ERROR}
    red = run_outcome(tmp_path, files, "--expect-red", "test_b.py::test_bad")
    assert red.returncode == GREEN, red.stdout
    assert "Подлог: ПОКРАСНЕЛ" in red.stdout


@pytest.mark.parametrize("target,word", [
    ("test_a.py::test_ok", "не покраснел"),
    ("test_db.py::test_needs_db", "это не краснота"),
    ("test_zzz.py::test_none", "не найден"),
], ids=["passed", "error", "absent"])
def test_probe_not_red(tmp_path, target, word):
    files = {"test_a.py": PASS, "test_b.py": FAIL, "test_db.py": ERROR}
    got = run_outcome(tmp_path, files, "--expect-red", target)
    assert got.returncode == PROBE_FAILED, got.stdout
    assert word in got.stdout


def test_probe_with_environment_refusal_did_not_happen(tmp_path):
    # отказ окружения выглядит краснотой по коду возврата, но подлогом не является
    got = run_outcome(tmp_path, {"test_b.py": FAIL, "test_broken.py": BROKEN_IMPORT},
                      "--expect-red", "test_b.py::test_bad")
    assert got.returncode == PROBE_FAILED, got.stdout
    assert "подлог не состоялся" in got.stdout


PARAM_SPACES = ("import pytest\n@pytest.mark.parametrize('name', ['a b.tgz', 'c'])\n"
                "def test_names(name):\n    assert name != 'c'\n")


def test_parametrized_ids_with_spaces_are_counted(tmp_path):
    # нашлось на самом наборе: «[a b.tgz]» не узнавался, и счёт строк не сходился с итогом
    got = run_outcome(tmp_path, {"test_p.py": PARAM_SPACES}, "--expect-red", "test_p.py::test_names[c]")
    assert "прошли 1, не прошли 1, не состоялись 0 из 2" in got.stdout, got.stdout
    assert got.returncode == GREEN, got.stdout
    red = run_outcome(tmp_path, {}, "--expect-red", "test_p.py::test_names[a b.tgz]")
    assert red.returncode == PROBE_FAILED and "не покраснел" in red.stdout, red.stdout


def test_same_test_matches_windows_paths():
    assert outcome.same_test("tests\\test_x.py::test_y", "tests/test_x.py::test_y")
    assert outcome.same_test("test_x.py::test_y", "tests/test_x.py::test_y")
    assert not outcome.same_test("test_x.py::test_y", "tests/test_x.py::test_yy")
