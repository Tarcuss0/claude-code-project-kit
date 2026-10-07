"""Тесты server/release.sh на временном каталоге: настоящий bash, настоящий curl,
локальный HTTP-сервер вместо сервиса. Здоровье релиза = файл `healthy` внутри релиза."""
import io
import subprocess
import tarfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parent.parent / "server" / "release.sh"


class _Health:
    def __init__(self, root: Path):
        outer = root

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                ok = (outer / "current" / "healthy").exists()
                self.send_response(200 if ok else 503)
                self.end_headers()

            def log_message(self, *args):
                pass

        self.server = HTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def stop(self):
        self.server.shutdown()


@pytest.fixture
def env(tmp_path):
    root = tmp_path / "app"
    root.mkdir()
    health = _Health(root)
    log = tmp_path / "restarts.log"
    write_conf(root, log, health.port)
    yield root, log
    health.stop()


def write_conf(root: Path, log: Path, port: int, **extra):
    values = {
        "KEEP_RELEASES": "3",
        "RESTART_CMD": f'echo "$RELEASE_DIR" >> {log}',
        "HEALTH_URL": f"http://127.0.0.1:{port}/health",
        "HEALTH_WAIT": "2",
        "HEALTH_INTERVAL": "0.2",
    }
    values.update(extra)
    (root / "release.env").write_text("".join(f"{k}={v}\n" for k, v in values.items()))


def make_archive(root: Path, name: str, files: dict, extra_members=()):
    incoming = root / "incoming"
    incoming.mkdir(exist_ok=True)
    with tarfile.open(incoming / name, "w:gz") as tar:
        for path, text in files.items():
            data = text.encode()
            info = tarfile.TarInfo(path)
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
        for info in extra_members:
            tar.addfile(info)


def run(root: Path, *args):
    return subprocess.run(
        ["bash", str(SCRIPT), "--root", str(root), *args],
        capture_output=True, text=True, timeout=60,
    )


def current_name(root: Path) -> str:
    return (root / "current").resolve().name


def restarts(log: Path) -> list:
    return log.read_text().splitlines() if log.exists() else []


GOOD = {"healthy": "", "app.txt": "v"}


def test_first_receive_switches_and_restarts(env):
    root, log = env
    make_archive(root, "app-20260101-000001.tgz", GOOD)
    got = run(root, "receive", "app-20260101-000001.tgz")
    assert got.returncode == 0, got.stdout + got.stderr
    assert current_name(root) == "app-20260101-000001"
    assert len(restarts(log)) == 1
    assert "ОК" in got.stdout


def test_bad_release_rolls_back_to_previous(env):
    root, log = env
    make_archive(root, "app-20260101-000001.tgz", GOOD)
    assert run(root, "receive", "app-20260101-000001.tgz").returncode == 0
    make_archive(root, "app-20260101-000002.tgz", {"app.txt": "no healthy file"})
    got = run(root, "receive", "app-20260101-000002.tgz")
    assert got.returncode == 1
    assert current_name(root) == "app-20260101-000001"
    assert (root / "releases" / "app-20260101-000002.failed").is_dir()
    assert not (root / "releases" / "app-20260101-000002").exists()
    # перезапуск: первая выкатка, неудачная новая, возврат на прежний
    assert len(restarts(log)) == 3
    assert restarts(log)[-1].endswith("app-20260101-000001")


def test_first_release_unhealthy_has_nothing_to_roll_back_to(env):
    root, _ = env
    make_archive(root, "app-20260101-000001.tgz", {"app.txt": "x"})
    got = run(root, "receive", "app-20260101-000001.tgz")
    assert got.returncode == 1
    assert "откатываться некуда" in got.stderr


def test_pre_switch_failure_leaves_production_untouched(env):
    root, log = env
    make_archive(root, "app-20260101-000001.tgz", GOOD)
    assert run(root, "receive", "app-20260101-000001.tgz").returncode == 0
    restarts_before = len(restarts(log))
    write_conf(root, log, int(_port(root)), PRE_SWITCH_CMD="exit 3")
    make_archive(root, "app-20260101-000002.tgz", GOOD)
    got = run(root, "receive", "app-20260101-000002.tgz")
    assert got.returncode == 1
    assert current_name(root) == "app-20260101-000001"
    assert len(restarts(log)) == restarts_before
    assert not (root / "releases" / "app-20260101-000002").exists()


def _port(root: Path) -> str:
    for line in (root / "release.env").read_text().splitlines():
        if line.startswith("HEALTH_URL="):
            return line.rsplit(":", 1)[1].split("/")[0]
    raise AssertionError("нет HEALTH_URL")


def test_pre_switch_runs_in_release_dir_with_release_dir_env(env):
    root, log = env
    marker = root / "pre.txt"
    write_conf(root, log, int(_port(root)), PRE_SWITCH_CMD=f'pwd > {marker}; echo "$RELEASE_DIR" >> {marker}')
    make_archive(root, "app-20260101-000001.tgz", GOOD)
    assert run(root, "receive", "app-20260101-000001.tgz").returncode == 0
    lines = marker.read_text().splitlines()
    assert lines[0] == lines[1]
    assert lines[0].endswith("releases/app-20260101-000001")


@pytest.mark.parametrize("name", ["../x.tgz", "a/b.tgz", "x.zip", ".hidden.tgz", "a b.tgz", ""])
def test_unsafe_archive_names_are_rejected(env, name):
    root, _ = env
    got = run(root, "receive", name)
    assert got.returncode == 1
    assert "недопустимое имя" in got.stderr


def test_archive_with_parent_path_is_rejected(env):
    root, log = env
    make_archive(root, "app-20260101-000001.tgz", {**GOOD, "../evil.txt": "x"})
    got = run(root, "receive", "app-20260101-000001.tgz")
    assert got.returncode == 1
    assert "абсолютные пути или '..'" in got.stderr
    assert not (root / "evil.txt").exists()
    assert not (root / "releases" / "evil.txt").exists()
    assert restarts(log) == []


def test_archive_with_absolute_path_is_rejected(env):
    root, _ = env
    make_archive(root, "app-20260101-000001.tgz", {**GOOD, "/tmp/abs-evil.txt": "x"})
    got = run(root, "receive", "app-20260101-000001.tgz")
    assert got.returncode == 1
    assert "абсолютные пути или '..'" in got.stderr


def test_same_release_name_twice_is_refused(env):
    root, _ = env
    make_archive(root, "app-20260101-000001.tgz", GOOD)
    assert run(root, "receive", "app-20260101-000001.tgz").returncode == 0
    got = run(root, "receive", "app-20260101-000001.tgz")
    assert got.returncode == 1
    assert "уже есть" in got.stderr


def test_prune_keeps_newest_and_never_current(env):
    root, _ = env
    for i in range(1, 6):
        name = f"app-20260101-00000{i}.tgz"
        make_archive(root, name, GOOD)
        assert run(root, "receive", name).returncode == 0
    kept = sorted(p.name for p in (root / "releases").iterdir())
    assert kept == ["app-20260101-000003", "app-20260101-000004", "app-20260101-000005"]
    assert current_name(root) == "app-20260101-000005"


def test_prune_never_removes_current_even_when_its_name_is_oldest(env):
    root, _ = env
    for i in (3, 4, 5):
        name = f"app-20260101-00000{i}.tgz"
        make_archive(root, name, GOOD)
        assert run(root, "receive", name).returncode == 0
    # выкатка архива со старым именем: current оказывается самым «старым» по имени
    make_archive(root, "app-20260101-000001.tgz", GOOD)
    assert run(root, "receive", "app-20260101-000001.tgz").returncode == 0
    assert current_name(root) == "app-20260101-000001"
    assert (root / "releases" / "app-20260101-000001").is_dir()


def test_failed_release_is_not_a_rollback_candidate(env):
    root, _ = env
    make_archive(root, "app-20260101-000001.tgz", GOOD)
    assert run(root, "receive", "app-20260101-000001.tgz").returncode == 0
    make_archive(root, "app-20260101-000002.tgz", {"x": "bad"})
    assert run(root, "receive", "app-20260101-000002.tgz").returncode == 1
    make_archive(root, "app-20260101-000003.tgz", GOOD)
    assert run(root, "receive", "app-20260101-000003.tgz").returncode == 0
    got = run(root, "rollback")
    assert got.returncode == 0, got.stdout + got.stderr
    assert current_name(root) == "app-20260101-000001"


def test_rollback_goes_to_previous_and_restarts(env):
    root, log = env
    for i in (1, 2):
        name = f"app-20260101-00000{i}.tgz"
        make_archive(root, name, GOOD)
        assert run(root, "receive", name).returncode == 0
    got = run(root, "rollback")
    assert got.returncode == 0, got.stdout + got.stderr
    assert current_name(root) == "app-20260101-000001"
    assert restarts(log)[-1].endswith("app-20260101-000001")
    assert "Схема базы осталась новой" in got.stdout


def test_rollback_with_nothing_older_refuses(env):
    root, _ = env
    make_archive(root, "app-20260101-000001.tgz", GOOD)
    assert run(root, "receive", "app-20260101-000001.tgz").returncode == 0
    got = run(root, "rollback")
    assert got.returncode == 1
    assert "прежнего релиза нет" in got.stderr


def test_rollback_to_named_release(env):
    root, _ = env
    for i in (1, 2, 3):
        name = f"app-20260101-00000{i}.tgz"
        make_archive(root, name, GOOD)
        assert run(root, "receive", name).returncode == 0
    got = run(root, "rollback", "app-20260101-000001")
    assert got.returncode == 0, got.stdout + got.stderr
    assert current_name(root) == "app-20260101-000001"


def test_second_run_while_locked_is_refused(env):
    root, _ = env
    make_archive(root, "app-20260101-000001.tgz", GOOD)
    holder = subprocess.Popen(
        ["bash", "-c", f'exec 9>"{root}/.release.lock"; flock 9; sleep 5'])
    try:
        # дать держателю взять замок
        for _ in range(50):
            if (root / ".release.lock").exists():
                break
        import time
        time.sleep(0.5)
        got = run(root, "receive", "app-20260101-000001.tgz")
        assert got.returncode == 1
        assert "другой приём" in got.stderr
    finally:
        holder.kill()


def test_conf_values_with_equals_sign_survive(env):
    root, log = env
    marker = root / "eq.txt"
    write_conf(root, log, int(_port(root)), PRE_SWITCH_CMD=f"echo a=b=c > {marker}")
    make_archive(root, "app-20260101-000001.tgz", GOOD)
    assert run(root, "receive", "app-20260101-000001.tgz").returncode == 0
    assert marker.read_text().strip() == "a=b=c"


def test_too_small_keep_releases_is_rejected(env):
    root, log = env
    write_conf(root, log, int(_port(root)), KEEP_RELEASES="1")
    make_archive(root, "app-20260101-000001.tgz", GOOD)
    got = run(root, "receive", "app-20260101-000001.tgz")
    assert got.returncode == 1
    assert "KEEP_RELEASES" in got.stderr


def test_old_archives_are_removed_with_their_releases(env):
    root, _ = env
    for i in range(1, 6):
        name = f"app-20260101-00000{i}.tgz"
        make_archive(root, name, GOOD)
        assert run(root, "receive", name).returncode == 0
    left = sorted(p.name for p in (root / "incoming").iterdir())
    assert left == ["app-20260101-000003.tgz", "app-20260101-000004.tgz", "app-20260101-000005.tgz"]


def test_only_two_failed_releases_are_kept(env):
    root, _ = env
    make_archive(root, "app-20260101-000001.tgz", GOOD)
    assert run(root, "receive", "app-20260101-000001.tgz").returncode == 0
    for i in range(2, 6):
        name = f"app-20260101-00000{i}.tgz"
        make_archive(root, name, {"x": "bad"})
        assert run(root, "receive", name).returncode == 1
    make_archive(root, "app-20260101-000006.tgz", GOOD)
    assert run(root, "receive", "app-20260101-000006.tgz").returncode == 0
    failed = sorted(p.name for p in (root / "releases").iterdir() if p.name.endswith(".failed"))
    assert failed == ["app-20260101-000004.failed", "app-20260101-000005.failed"]
