# -*- coding: utf-8 -*-
"""Замок на общий ресурс (комплект, тестовую базу, стенд) на время одной команды.

Зачем. Два прогона в одном комплекте сносят базу друг у друга, а вывод печатает
твою ревизию: чужое вмешательство выглядит как дефект твоей правки. Договорённость
«не запускай, пока сосед гоняет» не держится, нужен замок.

Каким он должен быть (из живого проекта):
  - держится, пока жив процесс, и снимается сам после его смерти: никаких файлов
    «занято», которые надо убирать руками после упавшего прогона;
  - на Linux и macOS замок наследует и запущенная команда: если убили сам
    run-lock, а прогон ещё идёт, ресурс остаётся занятым, пока прогон не кончится;
  - замок привязан к процессу, а не к состоянию комплекта. Режим «оставить
    комплект поднятым» его не ломает: после конца команды комплект стоит поднятым,
    но свободным, и следующий прогон возьмёт замок как обычно;
  - занят: печатается, кем (сессия, pid, с какого времени, какая команда).

Держит замок ОС (flock на Linux и macOS, msvcrt.locking на Windows), файлы лежат
в .locks/ в корне репозитория. Файл замка не удаляется никогда: удалить файл,
который держит другой процесс, значит получить два замка на одно имя.

Запуск:
    python scripts/run-lock.py <ресурс> --session А -- pytest -q tests/zone_a
    python scripts/run-lock.py <ресурс> --wait 300 -- <команда>     ждать до 5 минут

Код выхода: код команды; 3, если замок не взят (ресурс занят) и команда не запускалась.
"""
import argparse
import datetime
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = Path(__file__).resolve().parent.parent
LOCKS = ROOT / ".locks"
NOT_STARTED = 3

if os.name == "nt":
    import msvcrt

    def try_lock(fd: int) -> bool:
        os.lseek(fd, 0, os.SEEK_SET)
        try:
            msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
            return True
        except OSError:
            return False
else:
    import fcntl

    def try_lock(fd: int) -> bool:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except OSError:
            return False


def holder_text(holder: Path) -> str:
    try:
        info = json.loads(holder.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return "кем, неизвестно (сведений о держателе нет)"
    return (f"сессия {info.get('session') or '?'}, pid {info.get('pid')}, "
            f"с {info.get('started')}, команда: {info.get('command')}")


def main() -> int:
    argv = sys.argv[1:]
    if "--" not in argv:
        print("ОТКАЗ: после имени ресурса нужен «--» и команда. Пример: run-lock.py db_a -- pytest -q")
        return NOT_STARTED
    cut = argv.index("--")
    ap = argparse.ArgumentParser(description="Замок на общий ресурс на время команды")
    ap.add_argument("resource", help="имя ресурса: комплект, база, стенд")
    ap.add_argument("--session", default=os.environ.get("SESSION", ""), help="буква сессии")
    ap.add_argument("--wait", type=float, default=0, help="сколько секунд ждать свободного замка")
    args = ap.parse_args(argv[:cut])
    command = argv[cut + 1:]
    if not command:
        print("ОТКАЗ: после «--» нет команды")
        return NOT_STARTED
    if not re.fullmatch(r"[\w.-]+", args.resource):
        print(f"ОТКАЗ: имя ресурса «{args.resource}»: только буквы, цифры, точка, дефис, подчёркивание")
        return NOT_STARTED

    LOCKS.mkdir(exist_ok=True)
    lock_path = LOCKS / f"{args.resource}.lock"
    holder = LOCKS / f"{args.resource}.holder.json"
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o644)
    if os.name == "nt" and os.fstat(fd).st_size == 0:
        os.write(fd, b"\0")  # msvcrt.locking запирает байт, ему нужно, чтобы байт был

    deadline = time.monotonic() + args.wait
    announced = False
    while not try_lock(fd):
        if time.monotonic() >= deadline:
            print(f"НЕ НАЧАТ: ресурс «{args.resource}» занят: {holder_text(holder)}")
            print("Команда не запускалась. Подожди или возьми свой комплект.")
            os.close(fd)
            return NOT_STARTED
        if not announced:
            print(f"ресурс «{args.resource}» занят ({holder_text(holder)}), жду до {args.wait:.0f} с")
            announced = True
        time.sleep(0.5)

    me = {
        "session": args.session, "pid": os.getpid(),
        "started": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "command": " ".join(command),
    }
    holder.write_text(json.dumps(me, ensure_ascii=False), encoding="utf-8")
    print(f"замок «{args.resource}» взят")
    try:
        if os.name == "nt":
            child = subprocess.Popen(command)
        else:
            # Команда наследует дескриптор: замок живёт, пока жив хотя бы один из двух процессов.
            child = subprocess.Popen(command, pass_fds=(fd,))
        try:
            code = child.wait()
        except KeyboardInterrupt:
            code = child.wait()
    except FileNotFoundError:
        print(f"ОТКАЗ: команда не найдена: {command[0]}")
        code = NOT_STARTED
    finally:
        try:
            info = json.loads(holder.read_text(encoding="utf-8"))
            if info.get("pid") == os.getpid():
                holder.unlink()
        except (OSError, ValueError):
            pass
        os.close(fd)
    print(f"замок «{args.resource}» снят, код команды {code}")
    return code


if __name__ == "__main__":
    sys.exit(main())
