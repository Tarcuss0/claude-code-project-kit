import subprocess
import sys
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parent.parent / "scripts"
sys.path.insert(0, str(SCRIPTS))

from dburl import parse_database_url, read_database_url  # noqa: E402


def make_url(scheme: str, user: str, password: str, host: str, tail: str) -> str:
    # собираем кусками, чтобы в тексте теста не было готового URL с паролем
    return scheme + "://" + user + ":" + password + "@" + host + tail


def test_plain_url():
    url = make_url("postgresql", "app", "secretpw", "db.internal", ":5432/main")
    assert parse_database_url(url) == ("app", "secretpw", "db.internal", "5432", "main")


def test_asyncpg_scheme_is_normalized():
    url = make_url("postgresql+asyncpg", "app", "secretpw", "10.0.0.1", ":6432/main")
    assert parse_database_url(url) == ("app", "secretpw", "10.0.0.1", "6432", "main")


def test_percent_in_password_is_kept_as_written():
    url = make_url("postgresql", "app", "p" + "%" + "ss" + "%" + "w0", "db", ":5432/main")
    user, password, *_ = parse_database_url(url)
    assert user == "app"
    assert password == "p%ss%w0"


def test_valid_percent_escape_is_not_decoded():
    # %41 это валидная последовательность: декодирование превратило бы её в «A»
    url = make_url("postgresql", "app", "ab" + "%" + "41", "db", ":5432/main")
    assert parse_database_url(url)[1] == "ab%41"


def test_default_port():
    url = make_url("postgresql", "app", "secretpw", "db", "/main")
    assert parse_database_url(url)[3] == "5432"


def test_url_without_scheme_is_rejected():
    with pytest.raises(ValueError):
        parse_database_url("app@db/main")


def test_read_from_env_file_with_quotes(tmp_path):
    env = tmp_path / ".env"
    url = make_url("postgresql", "app", "secretpw", "db", ":5432/main")
    env.write_text("OTHER=1\nDATABASE_URL=\"" + url + "\"\n", encoding="utf-8")
    assert read_database_url(env) == url


def test_missing_database_url_is_error(tmp_path):
    env = tmp_path / ".env"
    env.write_text("OTHER=1\n", encoding="utf-8")
    with pytest.raises(ValueError):
        read_database_url(env)


def test_cli_prints_pipe_separated_line(tmp_path):
    env = tmp_path / ".env"
    url = make_url("postgresql+asyncpg", "app", "p" + "%" + "x", "db", ":5432/main")
    env.write_text("DATABASE_URL=" + url + "\n", encoding="utf-8")
    result = subprocess.run(
        [sys.executable, str(SCRIPTS / "dburl.py"), str(env)],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0
    assert result.stdout.strip() == "app|p%x|db|5432|main"


def test_cli_fails_without_database_url(tmp_path):
    env = tmp_path / ".env"
    env.write_text("OTHER=1\n", encoding="utf-8")
    result = subprocess.run(
        [sys.executable, str(SCRIPTS / "dburl.py"), str(env)],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 1
    assert "DATABASE_URL" in result.stderr
