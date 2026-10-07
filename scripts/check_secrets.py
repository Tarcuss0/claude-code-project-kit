#!/usr/bin/env python3
"""Проверка репозитория на секреты перед коммитом и пушем.

Запуск: python scripts/check_secrets.py            (все отслеживаемые файлы git)
        python scripts/check_secrets.py --staged   (только то, что уже в индексе)
Код выхода 1, если что-то найдено. Значения секретов в вывод не попадают.
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

PATTERNS = {
    "токен Telegram-бота": re.compile(r"\b\d{8,10}:[A-Za-z0-9_-]{35}\b"),
    "ключ вида sk-...": re.compile(r"\bsk-[A-Za-z0-9_-]{20,}\b"),
    "ключ OpenRouter": re.compile(r"\bsk-or-v1-[A-Za-z0-9]{20,}\b"),
    "приватный ключ": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"),
    "api_hash (32 hex) рядом с api_hash": re.compile(r"api_hash\W{1,5}[0-9a-f]{32}\b", re.I),
    "пароль в URL соединения": re.compile(r"\b(?:postgres(?:ql)?(?:\+\w+)?|mysql|redis|amqp)://[^\s:@/]+:[^\s@/]{3,}@"),
    "AWS-ключ": re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    "строка секрета в коде": re.compile(
        r"""(?i)\b(?:password|passwd|secret|token|api[_-]?key)\b\s*[:=]\s*["'][^"'\s]{12,}["']"""
    ),
}

FORBIDDEN_NAMES = [
    re.compile(r"(^|/)\.env($|\.)(?!example)"),
    re.compile(r"\.session(-journal)?$"),
    re.compile(r"(^|/)state\.json$"),
    re.compile(r"\.dump$"),
    re.compile(r"(^|/)id_(rsa|ed25519)"),
]

SKIP_SUFFIXES = {".png", ".jpg", ".jpeg", ".gif", ".pdf", ".ico", ".woff", ".woff2", ".zip", ".gz", ".bundle", ".lock"}
MAX_BYTES = 2_000_000


def tracked_files(staged: bool) -> list[str]:
    cmd = ["git", "diff", "--cached", "--name-only", "--diff-filter=ACM"] if staged else ["git", "ls-files"]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
        return [line for line in out.splitlines() if line]
    except (subprocess.CalledProcessError, FileNotFoundError):
        return [str(p) for p in Path(".").rglob("*") if p.is_file() and ".git" not in p.parts]


def main() -> int:
    staged = "--staged" in sys.argv
    problems: list[str] = []

    for name in tracked_files(staged):
        norm = name.replace("\\", "/")
        for rx in FORBIDDEN_NAMES:
            if rx.search(norm):
                problems.append(f"{norm}: файл не должен быть в репозитории")
                break

        p = Path(name)
        if p.suffix.lower() in SKIP_SUFFIXES or not p.is_file():
            continue
        # этот скрипт описывает шаблоны, сам себя не проверяем
        if p.name == "check_secrets.py":
            continue
        try:
            if p.stat().st_size > MAX_BYTES:
                continue
            text = p.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue

        for lineno, line in enumerate(text.splitlines(), 1):
            for label, rx in PATTERNS.items():
                if rx.search(line):
                    problems.append(f"{norm}:{lineno}: {label}")

    if problems:
        print("Найдены возможные секреты (значения не показаны):")
        for item in problems:
            print("  " + item)
        print("Проверь, убери из кода в .env и перевыпусти ключ, если он уже попадал в коммит.")
        return 1
    print("Секретов не найдено.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
