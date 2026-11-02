# -*- coding: utf-8 -*-
"""Коммит своих путей, когда в одном рабочем дереве работают несколько сессий.

Что бывает без него (всё из живого проекта):
  - обычные `git add` + `git commit` увозят то, что другая сессия подготовила
    в общем индексе: коммит одной сессии откатил семь путей другой;
  - обычный `git commit` берёт версию файла из индекса, а не с диска: вчерашний
    `git add` и сегодняшняя правка дают коммит со вчерашней версией;
  - ручной отдельный индекс (GIT_INDEX_FILE) с `git commit`: если между сборкой
    и записью успел закоммитить сосед, его правка тихо откатывается;
  - сборка через commit-tree и update-ref со старым значением гонку ловит, но
    без выравнивания общего индекса оставляет в нём подготовленный откат.

`git commit --only <пути>` закрывает всё это одной командой: берёт пути с диска
в отдельный индекс от текущего HEAD, пишет ссылку с проверкой старого значения
(при гонке отказ «cannot lock ref», а не тихий откат) и сам выравнивает общий
индекс по этим путям. Скрипт добавляет к нему то, что на слове не держится:
  1. пути только поимённо: каталоги и маски отвергаются; новый файл регистрируется
     через `git add -N` (путь без содержимого), иначе --only его не видит;
  2. пути только из своей зоны, если в docs/HANDOVER-<X>.md она заполнена;
  3. при гонке (чужой коммит или занятый index.lock) повтор на новом HEAD;
  4. после записи сверка: в коммите ровно названные пути и общий индекс
     по ним совпадает с HEAD. Расхождение печатается как ПЛОХО.

Запуск (из любого места внутри репозитория):
    python scripts/commit.py --session А -m "Что сделано" путь/к/файлу.py другой/файл.md

Строка «Сессия: X» дописывается в тело сама. Код выхода 0 только если коммит
записан и сверка состава прошла.
"""
import argparse
import os
import re
import subprocess
import sys
import time
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ATTEMPTS = 6
RACE = ("cannot lock ref", "index.lock", "is at", "but expected")


def git(top: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", *args], cwd=top, capture_output=True, text=True,
        encoding="utf-8", errors="replace",
    )


def fail(text: str) -> int:
    for line in text.strip().splitlines():
        print(f"ОТКАЗ: {line}")
    return 1


def zone_of(top: Path, session: str) -> list:
    """Префиксы зоны из строки «Каталоги и файлы, которыми владеет эта сессия:»."""
    handover = top / "docs" / f"HANDOVER-{session}.md"
    if not handover.is_file():
        return []
    for line in handover.read_text(encoding="utf-8-sig").splitlines():
        if "которыми владеет эта сессия" in line and ":" in line:
            tail = line.split(":", 1)[1]
            items = [p.strip().strip("`").replace("\\", "/") for p in re.split(r"[,;]", tail)]
            return [p for p in items if p]
    return []


def in_zone(path: str, zone: list) -> bool:
    for prefix in zone:
        p = prefix.lstrip("./")
        if path == p.rstrip("/") or path.startswith(p.rstrip("/") + "/"):
            return True
    return False


def normalize(top: Path, raw: str) -> str:
    full = raw if os.path.isabs(raw) else os.path.join(os.getcwd(), raw)
    try:
        # без разворота ссылок: путь симлинка внутри репозитория остаётся его путём
        rel = os.path.relpath(os.path.abspath(full), os.path.abspath(top))
        if rel.startswith(".."):
            rel = os.path.relpath(os.path.realpath(full), os.path.realpath(top))
    except ValueError:  # другой диск в Windows
        return ""
    rel = rel.replace("\\", "/")
    return "" if rel.startswith("../") or rel == ".." else rel


def main() -> int:
    ap = argparse.ArgumentParser(description="Коммит своих путей в общем рабочем дереве")
    ap.add_argument("--session", required=True, help="буква сессии: А, Б, В...")
    ap.add_argument("-m", dest="message", required=True, help="первая строка коммита")
    ap.add_argument("paths", nargs="+", help="файлы поимённо")
    args = ap.parse_args()

    found = git(Path.cwd(), "rev-parse", "--show-toplevel")
    if found.returncode != 0:
        return fail("здесь нет git-репозитория")
    top = Path(found.stdout.strip())

    paths, problems = [], []
    for raw in args.paths:
        if any(ch in raw for ch in "*?["):
            problems.append(f"{raw}: маски не принимаются, назови файлы поимённо")
            continue
        rel = normalize(top, raw)
        if not rel:
            problems.append(f"{raw}: путь вне репозитория")
            continue
        if (top / rel).is_dir():
            problems.append(f"{raw}: это каталог; назови файлы поимённо, иначе заденешь соседей")
            continue
        tracked = git(top, "ls-files", "--error-unmatch", "--", rel).returncode == 0
        if not (top / rel).exists() and not tracked:
            problems.append(f"{raw}: такого файла нет ни на диске, ни в git")
            continue
        paths.append(rel)
    if problems:
        return fail("\n".join(problems))
    paths = sorted(set(paths))

    zone = zone_of(top, args.session)
    if zone:
        outside = [p for p in paths if not in_zone(p, zone)]
        if outside:
            return fail(f"вне зоны сессии {args.session} ({', '.join(zone)}): {', '.join(outside)}")
    else:
        print(f"НЕ СОСТОЯЛАСЬ сверка зоны: в docs/HANDOVER-{args.session}.md зона не заполнена, "
              "пути не сверены с зоной")

    changed = git(top, "status", "--porcelain", "--untracked-files=all", "--", *paths).stdout.strip()
    if not changed:
        return fail(f"в названных путях нет изменений: {', '.join(paths)}")

    # Новый файл git commit --only не видит («pathspec did not match»). Обычный git add
    # положил бы содержимое в общий индекс, где его увезёт чужой коммит. git add -N
    # регистрирует только путь, без содержимого: содержимое --only возьмёт с диска.
    untracked = [p for p in paths if git(top, "ls-files", "--error-unmatch", "--", p).returncode != 0]
    if untracked:
        added = git(top, "add", "-N", "--", *untracked)
        if added.returncode != 0:
            return fail("не удалось зарегистрировать новые файлы (git add -N):\n" + added.stderr)

    body = args.message.strip()
    if f"Сессия: {args.session}" not in body:
        body += f"\n\nСессия: {args.session}"

    commit_id = ""
    for attempt in range(1, ATTEMPTS + 1):
        done = git(top, "commit", "--only", "-m", body, "--", *paths)
        out = (done.stdout or "") + (done.stderr or "")
        if done.returncode == 0:
            m = re.search(r"^\[[^\]]*?([0-9a-f]{7,40})\]", done.stdout, re.MULTILINE)
            commit_id = m.group(1) if m else ""
            break
        if any(word in out for word in RACE) and attempt < ATTEMPTS:
            print(f"гонка с другой сессией (попытка {attempt}): {out.strip().splitlines()[-1]}; "
                  "повторяю на новом HEAD")
            time.sleep(min(0.5 * attempt, 3))
            continue
        return fail("git commit не записал коммит:\n" + out)
    if not commit_id:
        return fail("git сказал «готово», но номера коммита в выводе нет: сверка состава невозможна")

    full = git(top, "rev-parse", commit_id).stdout.strip()
    got = git(top, "diff-tree", "--no-commit-id", "--name-only", "-r", "--root", full).stdout.split("\n")
    got = sorted(p for p in got if p)
    extra = sorted(set(got) - set(paths))
    missing = sorted(set(paths) - set(got))
    stale = git(top, "diff", "--cached", "--name-only", full, "--", *paths).stdout.split()

    print(f"коммит {full[:7]}: {len(got)} путей")
    for p in got:
        print(f"  {p}")
    bad = False
    if extra:
        bad = True
        print(f"ПЛОХО: в коммит попали чужие пути: {', '.join(extra)}")
    if missing:
        bad = True
        print(f"ПЛОХО: названные пути не попали в коммит: {', '.join(missing)}")
    if stale:
        bad = True
        print(f"ПЛОХО: общий индекс по своим путям расходится с коммитом: {', '.join(stale)}")
    if bad:
        print("Коммит записан, но состав не тот. Не исправляй сам: покажи этот вывод человеку.")
        return 1
    print("сверка состава: ровно названные пути, общий индекс по ним совпадает с коммитом")
    return 0


if __name__ == "__main__":
    sys.exit(main())
