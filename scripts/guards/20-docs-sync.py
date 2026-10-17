# -*- coding: utf-8 -*-
# about: с последней выкатки менялись миграции или зависимости, и docs/ARCHITECTURE.md правился (или в коммите сказано «Архитектура: без изменений»)
"""Сторож: документ об архитектуре не отстаёт от кода.

Правило «обновляй схему вместе с кодом» держится на просьбе к сессии, а
просьба работает, пока о ней помнят. Этот сторож превращает её в проверку.

Сравнивается дерево с коммитом, который выкачен последним (маркер
`deploy/deployed.json`, его ведёт сама выкатка). Если за это время менялись
файлы из `RULES` (миграции, схема, манифесты зависимостей), то должно быть
одно из двух:

  1. в том же промежутке менялся `docs/ARCHITECTURE.md`;
  2. в теле любого коммита промежутка есть строка
     `Архитектура: без изменений`. Это явное заявление «я посмотрел, схема
     не меняется», его видно в `git log`, и оно не даёт отговориться молчанием.

Первой выкатки ещё не было, маркера нет: сравнивать не с чем, сторож говорит
об этом и пропускает.

Чего он не видит: правился ли документ по делу. Файл могли тронуть ради
опечатки. Это проверка «о документе вспомнили», а не «документ верен».
"""
import importlib.util
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
DOC = "docs/ARCHITECTURE.md"

# Что считается изменением, о котором документ должен знать. Правь под проект.
RULES = (
    ("модель данных", (
        r"(^|/)migrations/",
        r"(^|/)alembic/versions/",
        r"^docs/schema\.sql$",
    )),
    ("стек и зависимости", (
        r"(^|/)requirements[^/]*\.txt$",
        r"(^|/)package\.json$",
        r"(^|/)pyproject\.toml$",
    )),
)
TRAILER = re.compile(r"^Архитектура:\s*без изменений", re.IGNORECASE | re.MULTILINE)

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")


def git(*args: str) -> tuple[int, str]:
    done = subprocess.run(
        ["git", *args], cwd=ROOT, capture_output=True, text=True,
        encoding="utf-8", errors="replace",
    )
    return done.returncode, done.stdout


def load_deployed():
    path = ROOT / "scripts" / "deployed.py"
    spec = importlib.util.spec_from_file_location("deployed_marker", path)
    if not path.is_file() or spec is None or spec.loader is None:
        return None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> int:
    deployed = load_deployed()
    if deployed is None:
        print("ПЛОХО: нет scripts/deployed.py, не от чего считать промежуток")
        return 1

    if not deployed.MARKER.is_file():
        print("ок: выкаток этим скриптом ещё не было, сравнивать не с чем")
        return 0

    try:
        state = json.loads(deployed.MARKER.read_text(encoding="utf-8-sig"))
    except (json.JSONDecodeError, OSError) as err:
        print(f"ПЛОХО: маркер выкатки не читается ({err})")
        return 1

    base, why = deployed.base_commit(state)
    if not base:
        print(f"ПЛОХО: не от чего считать промежуток: {why}")
        return 1

    code, out = git("diff", "--name-only", base, "HEAD")
    if code != 0:
        print(f"ПЛОХО: не удалось сравнить HEAD с выкаченным коммитом {base[:7]} (git вернул {code})")
        return 1
    changed = [line.strip() for line in out.splitlines() if line.strip()]

    hits: list[tuple[str, str]] = []
    for label, patterns in RULES:
        for path in changed:
            if any(re.search(p, path) for p in patterns):
                hits.append((label, path))
    if not hits:
        print(f"ок: с выкаченного {base[:7]} модель данных и зависимости не менялись")
        return 0

    if DOC in changed:
        print(f"ок: с выкаченного {base[:7]} правился {DOC}")
        return 0

    code, bodies = git("log", f"{base}..HEAD", "--format=%B")
    if code == 0 and TRAILER.search(bodies):
        print("ок: в коммитах заявлено «Архитектура: без изменений»")
        return 0

    print(f"ПЛОХО: с выкаченного {base[:7]} менялось, а {DOC} нет:")
    for label, path in hits[:8]:
        print(f"ПЛОХО:   {label}: {path}")
    if len(hits) > 8:
        print(f"ПЛОХО:   и ещё {len(hits) - 8}")
    if not (ROOT / DOC).is_file():
        print(f"ПЛОХО: файла {DOC} нет, создай его по docs/ARCHITECTURE-TEMPLATE.md")
    print("ПЛОХО: поправь документ или допиши в тело коммита строку «Архитектура: без изменений»")
    return 1


if __name__ == "__main__":
    sys.exit(main())
