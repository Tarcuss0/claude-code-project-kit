import subprocess
import sys
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "check_secrets.py"


def run_in_repo(repo: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        cwd=repo,
        capture_output=True,
        text=True,
    )


@pytest.fixture
def repo(tmp_path):
    subprocess.run(["git", "init", "-q"], cwd=tmp_path, check=True)
    return tmp_path


def add(repo: Path, name: str, text: str) -> None:
    path = repo / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    subprocess.run(["git", "add", name], cwd=repo, check=True)


def test_clean_repo_passes(repo):
    add(repo, "app.py", "print('hello')\n")
    result = run_in_repo(repo)
    assert result.returncode == 0


def test_telegram_token_is_found_and_value_is_not_printed(repo):
    token = "1" * 9 + ":" + "A" * 35
    add(repo, "bot.py", "TOKEN_VALUE = '" + token + "'\n")
    result = run_in_repo(repo)
    assert result.returncode == 1
    assert "bot.py:1" in result.stdout
    assert token not in result.stdout


def test_hardcoded_secret_string_is_found(repo):
    line = "api_key = " + '"' + "abcdefghijkl" + "1234567890" + '"' + "\n"
    add(repo, "config.py", line)
    result = run_in_repo(repo)
    assert result.returncode == 1
    assert "config.py:1" in result.stdout


def test_db_url_with_password_is_found(repo):
    url = "postgresql://" + "app:" + "secretpw" + "@db:5432/main"
    add(repo, "settings.py", "URL = '" + url + "'\n")
    assert run_in_repo(repo).returncode == 1


def test_private_key_is_found(repo):
    add(repo, "key.txt", "-----BEGIN " + "PRIVATE KEY-----\nabc\n")
    assert run_in_repo(repo).returncode == 1


def test_env_file_is_forbidden_by_name(repo):
    add(repo, ".env", "A=1\n")
    result = run_in_repo(repo)
    assert result.returncode == 1
    assert ".env" in result.stdout


def test_env_example_is_allowed(repo):
    add(repo, ".env.example", "A=\n")
    assert run_in_repo(repo).returncode == 0


def test_session_and_state_files_are_forbidden(repo):
    add(repo, "radar.session", "x")
    add(repo, "data/state.json", "{}")
    result = run_in_repo(repo)
    assert result.returncode == 1
    assert "radar.session" in result.stdout
    assert "state.json" in result.stdout


def test_staged_mode_checks_only_the_index(repo):
    # плохой файл уже закоммичен, в индексе только чистый
    add(repo, "old.py", "TOKEN_VALUE = '" + "1" * 9 + ":" + "A" * 35 + "'\n")
    subprocess.run(
        ["git", "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "x"],
        cwd=repo,
        check=True,
    )
    add(repo, "new.py", "x = 1\n")
    assert run_in_repo(repo, "--staged").returncode == 0
    assert run_in_repo(repo).returncode == 1
