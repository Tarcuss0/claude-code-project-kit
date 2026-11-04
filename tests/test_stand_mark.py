# -*- coding: utf-8 -*-
"""Тесты scripts/stand-mark.py: «стенд» это настоящий HTTP-сервер в отдельном потоке,
который отдаёт файл stand-mark.txt из временного каталога сборки."""
import socket
import subprocess
import sys
import threading
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "stand-mark.py"


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


@pytest.fixture
def stand(tmp_path):
    build = tmp_path / "build"
    build.mkdir()
    server = ThreadingHTTPServer(("127.0.0.1", 0), partial(QuietHandler, directory=str(build)))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield build, f"http://127.0.0.1:{server.server_address[1]}/stand-mark.txt"
    server.shutdown()
    server.server_close()


def mark(*args: str, cwd: Path = None) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(SCRIPT), *args], cwd=cwd, capture_output=True,
                          text=True, encoding="utf-8", timeout=60)


def py(code: str) -> list:
    return [sys.executable, "-c", code]


def test_stamp_writes_a_new_word_each_time(stand):
    build, _ = stand
    first = mark("stamp", str(build), "--session", "А")
    word1 = (build / "stand-mark.txt").read_text(encoding="utf-8").strip()
    second = mark("stamp", str(build), "--session", "А")
    word2 = (build / "stand-mark.txt").read_text(encoding="utf-8").strip()
    assert first.returncode == 0 and second.returncode == 0
    assert word1 == first.stdout.strip() and word1.startswith("А-")
    assert word1 != word2  # две сборки одной сессии различимы


@pytest.mark.parametrize("exit_code", [0, 5])
def test_same_mark_runs_command_and_returns_its_code(stand, tmp_path, exit_code):
    build, url = stand
    word = mark("stamp", str(build), "--session", "А").stdout.strip()
    got = mark("around", url, word, "--", *py(f"open(r'{tmp_path / 'ran'}', 'w'); raise SystemExit({exit_code})"))
    assert got.returncode == exit_code, got.stdout
    assert "та же до и после" in got.stdout
    assert (tmp_path / "ran").exists()


def test_foreign_mark_does_not_start(stand, tmp_path):
    build, url = stand
    mark("stamp", str(build), "--session", "Б")  # стенд собрала другая сессия
    got = mark("around", url, "А-mine-000000000000", "--", *py(f"open(r'{tmp_path / 'ran'}', 'w')"))
    assert got.returncode == 3, got.stdout
    assert "ЗАМЕР НЕ НАЧАТ" in got.stdout and "не из твоей сборки" in got.stdout
    assert not (tmp_path / "ran").exists()


def test_mark_changed_during_measure_is_not_held_even_if_command_passed(stand):
    build, url = stand
    word = mark("stamp", str(build), "--session", "А").stdout.strip()
    rebuild = f"open(r'{build / 'stand-mark.txt'}', 'w').write('Б-other-111111111111\\n')"
    got = mark("around", url, word, "--", *py(rebuild))
    assert got.returncode == 2, got.stdout
    assert "ЗАМЕР НЕ СОСТОЯЛСЯ" in got.stdout and "Б-other-111111111111" in got.stdout


def test_missing_mark_file_does_not_start(stand):
    _, url = stand
    got = mark("around", url, "А-x-1", "--", *py("pass"))
    assert got.returncode == 3
    assert "ответил 404" in got.stdout


def test_stand_down_does_not_start():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    got = mark("around", f"http://127.0.0.1:{port}/stand-mark.txt", "А-x-1", "--", *py("pass"))
    assert got.returncode == 3
    assert "не ответил" in got.stdout


def test_expected_mark_from_own_file(stand):
    build, url = stand
    mark("stamp", str(build), "--session", "А")
    got = mark("around", url, f"@{build / 'stand-mark.txt'}", "--", *py("pass"))
    assert got.returncode == 0, got.stdout


def test_html_page_is_not_a_mark(stand):
    build, url = stand
    (build / "stand-mark.txt").write_text("<html>\n<body>404</body>\n</html>\n", encoding="utf-8")
    got = mark("get", url)
    assert got.returncode == 1
    assert "не метка" in got.stdout
