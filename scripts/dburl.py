#!/usr/bin/env python3
"""Разбор DATABASE_URL из .env для shell-скриптов.

Печатает одну строку user|password|host|port|dbname.

Пароль берётся как написан, без декодирования процентов. Так знак `%` в пароле
не ломает разбор: psql и pg_dump при передаче всего URI пытаются декодировать
пароль и падают, а приложение (например, SQLAlchemy) одиночный `%` пропускает как есть.
Если пароль содержит `@`, `/` или `:`, он в URL должен быть закодирован, и этот скрипт
такой пароль не раскодирует.

Схема вида postgresql+asyncpg:// приводится к обычной.
"""
from __future__ import annotations

import sys
from pathlib import Path
from urllib.parse import urlsplit


def parse_database_url(url: str) -> tuple[str, str, str, str, str]:
    if "://" not in url:
        raise ValueError("в DATABASE_URL нет схемы (ожидается вид postgresql://...)")
    _, rest = url.split("://", 1)
    parts = urlsplit("postgresql://" + rest)
    return (
        parts.username or "",
        parts.password or "",
        parts.hostname or "",
        str(parts.port or 5432),
        (parts.path or "/").lstrip("/"),
    )


def read_database_url(env_path: str | Path) -> str:
    url = ""
    for line in Path(env_path).read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line.startswith("DATABASE_URL="):
            url = line.split("=", 1)[1].strip().strip('"').strip("'")
    if not url:
        raise ValueError("в .env нет DATABASE_URL")
    return url


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: dburl.py <path-to-.env>", file=sys.stderr)
        return 2
    try:
        print("|".join(parse_database_url(read_database_url(argv[1]))))
    except (OSError, ValueError) as exc:
        print(f"dburl: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
