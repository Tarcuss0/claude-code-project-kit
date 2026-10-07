# -*- coding: utf-8 -*-
"""Что сейчас на проде и что туда не уехало.

Вместо `git log origin/main..HEAD`. Тот ответ верен ровно до следующего чужого пуша:
`origin/main` в дереве это снимок последнего `fetch`, и после выкатки он устаревает молча.
Сессия читает его и числит выкаченное невыкаченным.

Маркер deploy/deployed.json пишет сама выкатка, в момент успеха, в дерево, из которого
выкатывала. Отставать ему не от чего.

Артефактов может быть сколько угодно (backend, frontend, worker...), по записи на каждый.
Они едут по отдельности, и выкатка одного оставляет остальные на прежнем коммите. Поэтому
невыкаченное считается от ОТСТАВШЕГО: коммит выкачен, только если он есть во всех.

Запуск:
    python scripts/deployed.py           состояние и список невыкаченного
    python scripts/deployed.py --short   одна строка, для отчёта
"""
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MARKER = ROOT / "deploy" / "deployed.json"
# Путь маркера в терминах git: по нему отличаются коммиты, которые сделала сама выкатка.
MARKER_GIT_PATH = "deploy/deployed.json"

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")


def git(*args: str) -> str:
    done = subprocess.run(
        ["git", *args], cwd=ROOT, capture_output=True, text=True,
        encoding="utf-8", errors="replace",
    )
    return done.stdout.strip() if done.returncode == 0 else ""


def is_marker_commit(sha: str) -> bool:
    """Коммит самой выкатки: тронут только файл маркера.

    Отличаем по составу файлов, а не по тексту сообщения: сообщение можно повторить руками,
    состав нет. Если рядом с маркером в коммите лежит что-то ещё, это работа человека, и
    выкаченной она не считается."""
    files = [f for f in git("show", "--name-only", "--format=", sha).splitlines() if f]
    return files == [MARKER_GIT_PATH]


def artifacts_of(state: dict) -> dict:
    """Записи об артефактах: всё, что не служебная история и имеет поле commit."""
    return {
        name: one for name, one in state.items()
        if name != "history" and isinstance(one, dict) and one.get("commit")
    }


def base_commit(state: dict) -> tuple:
    """От какого коммита считать невыкаченное и почему именно от него."""
    commits = {name: one["commit"] for name, one in artifacts_of(state).items()}
    unique = sorted(set(commits.values()))
    if not unique:
        return None, "в маркере нет ни одного артефакта"
    if len(unique) == 1:
        if len(commits) == 1:
            return unique[0], "выкачен только один артефакт"
        return unique[0], "все артефакты на одном коммите"
    common = git("merge-base", "--octopus", *unique)
    if not common:
        return None, "у артефактов нет общего предка: маркер разъехался"
    lagging = sorted(name for name, sha in commits.items() if sha == common)
    if lagging:
        return common, "считаем от отставшего: " + ", ".join(lagging)
    return common, "считаем от общего предка артефактов"


def line_of(name: str, one: dict) -> str:
    mark = "  ГРЯЗНОЕ ДЕРЕВО" if one.get("dirty") else ""
    return (
        f"  {name:<12} {one.get('commit_short', '?')}"
        f"  релиз {one.get('release', '?')}"
        f"  {one.get('deployed_at', '?')}{mark}"
    )


def unreleased(base: str) -> list:
    fresh = []
    for row in git("log", f"{base}..HEAD", "--format=%h%x09%s").splitlines():
        if not row.strip():
            continue
        sha, _, subject = row.partition("\t")
        full = git("rev-parse", sha)
        if full and is_marker_commit(full):
            # Коммит самой выкатки появляется ПОСЛЕ неё и потому всегда «невыкачен».
            # Считать его значит показывать ложную единицу после каждой выкатки.
            continue
        fresh.append((sha, subject))
    return fresh


def main() -> int:
    short = "--short" in sys.argv

    if not MARKER.is_file():
        print("Маркер выкатки не найден:", MARKER)
        print("Ни одной выкатки этим скриптом ещё не было, состояние прода известно только человеку.")
        return 0

    try:
        # utf-8-sig: PowerShell 5.1 с Set-Content -Encoding UTF8 ставит BOM, и старый
        # маркер мог остаться с ним. Без метки utf-8-sig читает как обычный UTF-8.
        state = json.loads(MARKER.read_text(encoding="utf-8-sig"))
    except (json.JSONDecodeError, OSError) as err:
        print(f"Маркер не читается ({err}). Файл: {MARKER}")
        return 1

    arts = artifacts_of(state)
    base, why = base_commit(state)
    fresh = unreleased(base) if base else []

    if short:
        where = git("rev-parse", "--short", base) if base else "—"
        print(f"прод: {where}, невыкачено {len(fresh)}")
        return 0

    print("На проде:")
    for name in sorted(arts):
        print(line_of(name, arts[name]))
    if any(one.get("dirty") for one in arts.values()):
        print()
        print("  ВНИМАНИЕ: артефакт собран из грязного дерева.")
        print("  Совпадение коммитов не значит, что на сервере содержимое репозитория:")
        print("  этого состояния нет ни в одном коммите.")

    print()
    if not base:
        print(why)
        return 0
    if not fresh:
        print("Не выкачено: ничего, всё что в дереве уехало.")
        if len({one["commit"] for one in arts.values()}) > 1:
            print(f"({why})")
        return 0
    print(f"Не выкачено ({len(fresh)}), новые сверху:")
    for sha, subject in fresh:
        print(f"  {sha}  {subject}")
    print()
    print(f"({why})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
