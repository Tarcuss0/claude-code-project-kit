# -*- coding: utf-8 -*-
"""Все сторожа дерева одним заходом. Зовётся из deploy.ps1 перед выкаткой.

Почему так, а не git-хук. Хук локален, снимается ключом --no-verify, не приезжает с
репозиторием и у трёх сессий будет в трёх состояниях. Плата, которую платят добровольно,
не взимается. Через выкатку проходит всё, и обойти её нельзя. Хук допустим как удобство
(увидеть раньше), но единственным местом быть не может.

Что запускается:
  1. check_secrets.py (если лежит рядом): токены, ключи, запрещённые файлы в дереве;
  2. каждый scripts/guards/*.py, имя которого не начинается с «_», по имени файла.

Мера, которую никто не зовёт, неотличима от работающей: поэтому сторож кладётся в
guards/ и сам оказывается на пути выкатки. Формат сторожа: guards/_template.py.
Проверкам, которым нужен поднятый стенд или долгая сборка, место в ручном прогоне
перед выкаткой, а не здесь.

Запуск:
    python scripts/checks.py
    python scripts/checks.py --quick     без сторожей с пометкой «# needs-db»
"""
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GUARDS = ROOT / "scripts" / "guards"
HEADER_LINES = 15

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")


def read_header(path: Path) -> dict:
    """Шапка сторожа: about, needs-db, cwd. Читаются только первые строки."""
    info = {"about": "", "needs_db": False, "cwd": ""}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()[:HEADER_LINES]
    except OSError:
        return info
    for line in lines:
        text = line.strip()
        if not text.startswith("#"):
            continue
        body = text.lstrip("#").strip()
        if body == "needs-db":
            info["needs_db"] = True
        elif body.startswith("about:"):
            info["about"] = body[len("about:"):].strip()
        elif body.startswith("cwd:"):
            info["cwd"] = body[len("cwd:"):].strip()
    return info


def discover() -> list:
    """(путь, about, needs_db, cwd) в порядке запуска."""
    found = []
    secrets = ROOT / "scripts" / "check_secrets.py"
    if secrets.is_file():
        found.append((secrets, "токены, ключи и запрещённые файлы в дереве", False, ""))
    if GUARDS.is_dir():
        for path in sorted(GUARDS.glob("*.py")):
            if path.name.startswith("_"):
                continue
            head = read_header(path)
            found.append((path, head["about"], head["needs_db"], head["cwd"]))
    return found


def run(path: Path, cwd: str) -> tuple:
    started = time.monotonic()
    workdir = (ROOT / cwd) if cwd else ROOT
    got = subprocess.run(
        [sys.executable, str(path)],
        cwd=workdir, capture_output=True, text=True,
        encoding="utf-8", errors="replace", timeout=600,
    )
    return got.returncode, (got.stdout or "") + (got.stderr or ""), time.monotonic() - started


def blamed_lines(out: str) -> list:
    """Человеку нужна причина, а не факт падения. Берём строки претензий, и только если
    их нет, хвост вывода: хвост часто состоит из соседних «ок» и итога, и отчёт выглядит
    рабочим, хотя что именно сломано, не говорит."""
    blamed = [
        line for line in out.splitlines()
        if "ПЛОХО" in line or line.startswith("ОТКАЗ") or "Traceback" in line
    ]
    return (blamed or out.strip().splitlines()[-12:])[:12]


def main() -> int:
    quick = "--quick" in sys.argv
    failed = []
    checks = discover()
    if not checks:
        print("Сторожей нет: ни check_secrets.py, ни файлов в scripts/guards/.")
        return 0

    for path, about, needs_db, cwd in checks:
        name = path.name
        if quick and needs_db:
            print(f"  пропуск  {name:<32} нужна база, а сказано --quick")
            continue
        code, out, spent = run(path, cwd)
        if code == 0:
            print(f"  ок       {name:<32} {spent:5.1f} с   {about}")
            continue
        failed.append(name)
        print(f"  ПЛОХО    {name:<32} {spent:5.1f} с   {about}")
        for line in blamed_lines(out):
            print("           " + line.strip())

    print()
    if failed:
        print(f"Не прошли: {', '.join(failed)}.")
        print("Выкатка остановлена, разбор выше.")
        return 1
    print("Сторожа дерева прошли.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
