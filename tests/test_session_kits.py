# -*- coding: utf-8 -*-
"""Тесты сторожа scripts/guards/30-session-kits.py на временном дереве с файлами HANDOVER."""
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
GUARD = ROOT / "scripts" / "guards" / "30-session-kits.py"
TEMPLATE = ROOT / "docs" / "HANDOVER-TEMPLATE.md"


@pytest.fixture
def tree(tmp_path):
    (tmp_path / "scripts" / "guards").mkdir(parents=True)
    (tmp_path / "docs").mkdir()
    shutil.copy(GUARD, tmp_path / "scripts" / "guards" / GUARD.name)
    shutil.copy(TEMPLATE, tmp_path / "docs" / TEMPLATE.name)  # шаблон не сессия
    return tmp_path


def handover(tree: Path, session: str, suffix: str = None, kit: str = None) -> None:
    """Файл сессии из настоящего шаблона: заполняются только две строки."""
    text = TEMPLATE.read_text(encoding="utf-8")
    if suffix is not None:
        text = text.replace("- Суффикс тестовой БД:", f"- Суффикс тестовой БД: `{suffix}`")
    if kit is not None:
        text = text.replace("- Комплект (контейнеры, стенд, порты), только свой:",
                            f"- Комплект (контейнеры, стенд, порты), только свой: {kit}")
    (tree / "docs" / f"HANDOVER-{session}.md").write_text(text, encoding="utf-8")


def run(tree: Path):
    got = subprocess.run([sys.executable, str(tree / "scripts" / "guards" / GUARD.name)], cwd=tree,
                         capture_output=True, text=True, encoding="utf-8")
    return got.returncode, got.stdout


def test_four_sessions_with_own_kits_pass(tree):
    for s, n in zip("АБВГ", range(4)):
        handover(tree, s, f"_{n}", f"compose -p proj_{n}, порты 81{n}0–81{n}9")
    code, out = run(tree)
    assert code == 0, out
    assert "4 сессий (А, Б, В, Г)" in out


def test_no_handover_files_is_not_held(tree):
    code, out = run(tree)
    assert code == 3
    assert out.startswith("НЕ СОСТОЯЛАСЬ")


def test_fourth_session_without_kit_fails(tree):
    for s, n in zip("АБВ", range(3)):
        handover(tree, s, f"_{n}", f"proj_{n}")
    handover(tree, "Г", "_3")  # комплект не заполнен
    code, out = run(tree)
    assert code == 1
    assert "HANDOVER-Г.md: комплект не заполнен" in out


def test_old_handover_without_kit_line_fails(tree):
    handover(tree, "А", "_a", "proj_a")
    (tree / "docs" / "HANDOVER-Б.md").write_text("## Зона\n\n- Суффикс тестовой БД: `_b`\n", encoding="utf-8")
    code, out = run(tree)
    assert code == 1
    assert "HANDOVER-Б.md: строки «комплект» нет" in out


@pytest.mark.parametrize("field", ["suffix", "kit"])
def test_shared_value_fails_and_names_both_sessions(tree, field):
    handover(tree, "А", "_a", "proj_a")
    if field == "suffix":
        handover(tree, "Б", "_A", "proj_b")  # регистр не делает суффикс другим
    else:
        handover(tree, "Б", "_b", "proj_a")
    code, out = run(tree)
    assert code == 1
    assert "у сессий А, Б: комплект общий" in out
