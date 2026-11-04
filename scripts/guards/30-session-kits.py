# -*- coding: utf-8 -*-
# about: у каждой сессии в docs/HANDOVER-X.md заполнены свой суффикс тестовой БД и свой комплект, без повторов
"""Сторож: у каждой сессии свой комплект, включая четвёртую.

Сессия без своего комплекта ходит в чужие: два прогона сносят базу друг у друга,
две сборки делят один стенд, и вывод винит твою правку. Завести комплект дешевле,
чем потом искать, чей прогон что сломал.

Читаются docs/HANDOVER-*.md (кроме шаблона), строки «Суффикс тестовой БД:» и
«Комплект ...:» в разделе «Зона». Проверяется:
  - у каждой сессии обе строки есть и заполнены;
  - ни один суффикс и ни один комплект не повторяется у двух сессий.

Файлов HANDOVER нет: сверять нечего, мера не состоялась (код 3).

Чего он не видит: совпадают ли записанные комплекты с тем, что на самом деле
поднято. Это проверка записи, а не машины.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
NOT_HELD = 3

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

FIELDS = (
    ("суффикс", re.compile(r"^\s*-\s*Суффикс тестовой БД[^:]*:(.*)$", re.IGNORECASE)),
    ("комплект", re.compile(r"^\s*-\s*Комплект[^:]*:(.*)$", re.IGNORECASE)),
)


def clean(value: str) -> str:
    return value.strip().strip("`").strip()


def main() -> int:
    files = sorted(p for p in (ROOT / "docs").glob("HANDOVER-*.md") if p.name != "HANDOVER-TEMPLATE.md")
    if not files:
        print("НЕ СОСТОЯЛАСЬ: файлов docs/HANDOVER-X.md нет, сверять комплекты нечего")
        return NOT_HELD

    problems, seen = [], {"суффикс": {}, "комплект": {}}
    for path in files:
        session = path.stem[len("HANDOVER-"):]
        lines = path.read_text(encoding="utf-8-sig").splitlines()
        for label, pattern in FIELDS:
            values = [clean(m.group(1)) for m in map(pattern.match, lines) if m]
            if not values:
                problems.append(f"{path.name}: строки «{label}» нет")
                continue
            if not values[0]:
                problems.append(f"{path.name}: {label} не заполнен")
                continue
            seen[label].setdefault(values[0].lower(), []).append(session)

    for label, owners in seen.items():
        for value, sessions in owners.items():
            if len(sessions) > 1:
                problems.append(f"{label} «{value}» записан у сессий {', '.join(sessions)}: комплект общий")

    sessions = ", ".join(p.stem[len("HANDOVER-"):] for p in files)
    if problems:
        for line in problems:
            print(f"ПЛОХО: {line}")
        print(f"ПЛОХО: сессия без своего комплекта ходит в чужие. Проверены: {sessions}")
        return 1
    print(f"ок: {len(files)} сессий ({sessions}), у каждой записаны свой суффикс и свой комплект")
    return 0


if __name__ == "__main__":
    sys.exit(main())
