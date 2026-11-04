# -*- coding: utf-8 -*-
"""Метка стенда: замер идёт на той сборке, которую ты собрал, и она не сменилась по ходу.

Зачем. Две сессии собирают один стенд, и одна меряет код другой: ответ честный,
но не на тот вопрос. Решение из живого проекта: в сборку кладётся файл с
уникальным словом, а перед замером и после него это слово спрашивается у стенда
по HTTP (через nginx, тем же путём, что и сам замер).

  метка не та до замера    ЗАМЕР НЕ НАЧАТ (код 3), команда не запускается;
  метка сменилась по ходу  ЗАМЕР НЕ СОСТОЯЛСЯ (код 2), что бы ни вернула команда;
  метка та же до и после   код самой команды.

Слова те же, что у scripts/outcome.py: «не состоялся» не краснота и не зелень.

Запуск:
    python scripts/stand-mark.py stamp <каталог-сборки> --session А
        положить <каталог>/stand-mark.txt с новым словом и напечатать его
    python scripts/stand-mark.py get <url>
        прочитать метку со стенда
    python scripts/stand-mark.py around <url> <ожидаемая-метка | @файл> -- <команда замера>
        замер, огороженный меткой; @файл: взять ожидаемую метку из своего stand-mark.txt

Отдача метки в nginx (без кэша, иначе «до» и «после» прочитают одно и то же):
    location = /stand-mark.txt {
        alias <каталог-текущей-сборки>/stand-mark.txt;
        add_header Cache-Control "no-store";
    }
"""
import subprocess
import sys
import urllib.error
import urllib.request
import uuid
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

NOT_HELD, NOT_STARTED = 2, 3
MARK_FILE = "stand-mark.txt"


def fetch(url: str) -> str:
    """Метка со стенда. Любая неудача: исключение со словами."""
    req = urllib.request.Request(url, headers={"Cache-Control": "no-cache", "Pragma": "no-cache"})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            body = resp.read(512).decode("utf-8", errors="replace")
    except urllib.error.HTTPError as err:
        raise RuntimeError(f"стенд ответил {err.code} на {url}") from None
    except (urllib.error.URLError, OSError) as err:
        raise RuntimeError(f"стенд не ответил на {url}: {getattr(err, 'reason', err)}") from None
    mark = body.strip()
    if not mark or "\n" in mark or len(mark) > 200:
        raise RuntimeError(f"по {url} пришла не метка (пусто, несколько строк или страница), а {mark[:60]!r}")
    return mark


def commit_short() -> str:
    try:
        got = subprocess.run(["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True, timeout=10)
        return got.stdout.strip() if got.returncode == 0 and got.stdout.strip() else "nogit"
    except (OSError, subprocess.SubprocessError):
        return "nogit"


def stamp(target: str, session: str) -> int:
    folder = Path(target)
    if not folder.is_dir():
        print(f"ОТКАЗ: каталога сборки {target} нет")
        return 1
    word = f"{session or 'x'}-{commit_short()}-{uuid.uuid4().hex[:12]}"
    (folder / MARK_FILE).write_text(word + "\n", encoding="utf-8")
    print(word)
    return 0


def around(url: str, expected: str, command: list) -> int:
    if expected.startswith("@"):
        try:
            expected = Path(expected[1:]).read_text(encoding="utf-8").strip()
        except OSError as err:
            print(f"ЗАМЕР НЕ НАЧАТ: своей метки не прочитать ({err})")
            return NOT_STARTED
    try:
        before = fetch(url)
    except RuntimeError as err:
        print(f"ЗАМЕР НЕ НАЧАТ: {err}")
        return NOT_STARTED
    if before != expected:
        print(f"ЗАМЕР НЕ НАЧАТ: на стенде метка «{before}», а твоя «{expected}»: "
              "стенд собран не из твоей сборки. Команда не запускалась.")
        return NOT_STARTED
    print(f"метка стенда «{before}» совпала, замер начат")
    try:
        code = subprocess.call(command)
    except FileNotFoundError:
        print(f"ОТКАЗ: команда не найдена: {command[0]}")
        return NOT_STARTED
    try:
        after = fetch(url)
    except RuntimeError as err:
        print(f"ЗАМЕР НЕ СОСТОЯЛСЯ: после замера {err}; код команды {code} не в счёт")
        return NOT_HELD
    if after != before:
        print(f"ЗАМЕР НЕ СОСТОЯЛСЯ: метка сменилась по ходу («{before}» → «{after}»): стенд пересобрали "
              f"посреди замера, код команды {code} не в счёт")
        return NOT_HELD
    print(f"метка стенда «{after}» та же до и после замера, код команды {code}")
    return code


def main(argv: list) -> int:
    if argv[:1] == ["stamp"] and len(argv) >= 2:
        session = argv[argv.index("--session") + 1] if "--session" in argv[:-1] else ""
        return stamp(argv[1], session)
    if argv[:1] == ["get"] and len(argv) == 2:
        try:
            print(fetch(argv[1]))
            return 0
        except RuntimeError as err:
            print(f"ОТКАЗ: {err}")
            return 1
    if argv[:1] == ["around"] and "--" in argv:
        cut = argv.index("--")
        head, command = argv[1:cut], argv[cut + 1:]
        if len(head) == 2 and command:
            return around(head[0], head[1], command)
    print(__doc__)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
