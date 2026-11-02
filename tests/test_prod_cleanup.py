# -*- coding: utf-8 -*-
"""Подлоги на каркас docs/PROD-CLEANUP-TEMPLATE.sql на настоящем Postgres.

Поднимается временный кластер, в нём учебная схема с тем, что ломает наивную чистку:
полиморфные ссылки без внешнего ключа, триггер, запрещающий удалять подтверждённое,
файлы с отметкой вместо удаления и сирота, оставшаяся от старых времён. Блоки
«ЗАПОЛНИ» каркаса заполняются под эту схему, остальное берётся из шаблона как есть.

Проверяется то, что требует схема чистки: контрольный проход доходит до COMMIT;
расхождение чисел, чужое имя, изменившаяся база и новая сирота откатывают всё,
и это проверяется счётом строк после отказа, а не доверием.

Нужны программы Postgres (initdb, pg_ctl, psql). Под root initdb не работает,
тогда тест пропускается: запускай под обычным пользователем (в CI так и есть)."""
import glob
import os
import re
import shutil
import socket
import subprocess
from pathlib import Path

import pytest

TEMPLATE = Path(__file__).resolve().parent.parent / "docs" / "PROD-CLEANUP-TEMPLATE.sql"


def pg_bin(name: str) -> str:
    found = shutil.which(name)
    if found and name != "psql":
        return found
    for path in sorted(glob.glob(f"/usr/lib/postgresql/*/bin/{name}"), reverse=True):
        return path
    return found or ""


NEEDED = {name: pg_bin(name) for name in ("initdb", "pg_ctl", "psql")}
pytestmark = [
    pytest.mark.skipif(not all(NEEDED.values()), reason="нет программ Postgres"),
    pytest.mark.skipif(hasattr(os, "geteuid") and os.geteuid() == 0, reason="initdb не работает под root"),
]

SCHEMA = """
CREATE TABLE counterparties(id bigint PRIMARY KEY, name text NOT NULL);
CREATE TABLE orders(id bigint PRIMARY KEY, title text NOT NULL,
                    counterparty_id bigint NOT NULL REFERENCES counterparties(id),
                    confirmed boolean NOT NULL DEFAULT false);
CREATE TABLE order_items(id bigint PRIMARY KEY, order_id bigint NOT NULL REFERENCES orders(id), sku text);
CREATE TABLE comments(id bigint PRIMARY KEY, owner_kind text NOT NULL, owner_id bigint NOT NULL, body text);
CREATE TABLE files(id bigint PRIMARY KEY, owner_kind text NOT NULL, owner_id bigint NOT NULL,
                   path text NOT NULL, deleted_at timestamptz);
CREATE FUNCTION forbid_confirmed_delete() RETURNS trigger AS $$
BEGIN
  IF OLD.confirmed THEN RAISE EXCEPTION 'подтверждённую заявку удалять нельзя'; END IF;
  RETURN OLD;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER orders_no_delete BEFORE DELETE ON orders FOR EACH ROW EXECUTE FUNCTION forbid_confirmed_delete();

INSERT INTO counterparties VALUES (1, 'ООО Ромашка'), (2, 'Тест Один'), (3, 'Тест Два');
INSERT INTO orders VALUES (1, 'Настоящая заявка', 1, true), (2, 'Проба', 2, false), (3, 'Проба подтверждённая', 3, true);
INSERT INTO order_items VALUES (1, 1, 'A'), (2, 1, 'B'), (3, 2, 'C'), (4, 3, 'D');
INSERT INTO comments VALUES
  (1, 'order', 1, 'настоящий'), (2, 'order', 2, 'проба'), (3, 'counterparty', 2, 'проба'),
  (4, 'counterparty', 999, 'сирота из прошлого');
INSERT INTO files VALUES (1, 'order', 1, 'real.pdf', NULL), (2, 'order', 2, 'test.pdf', NULL),
                         (3, 'order', 3, 'test2.pdf', NULL);
"""

FILL = {
    "names": """  ('counterparties', 1, 'name', 'ООО Ромашка'),
  ('counterparties', 2, 'name', 'Тест Один'),
  ('counterparties', 3, 'name', 'Тест Два'),
  ('orders', 1, 'title', 'Настоящая заявка'),
  ('orders', 2, 'title', 'Проба'),
  ('orders', 3, 'title', 'Проба подтверждённая')""",
    "expect": """  ('counterparties', 3, 2),
  ('orders', 3, 2),
  ('order_items', 4, 2),
  ('comments', 4, 2),
  ('files', 3, 0)""",
    "refs": """  ('comments', 'owner_kind', 'owner_id', 'order', 'orders', NULL),
  ('comments', 'owner_kind', 'owner_id', 'counterparty', 'counterparties', NULL),
  ('files', 'owner_kind', 'owner_id', 'order', 'orders', 'deleted_at IS NULL'),
  ('orders', NULL, 'counterparty_id', NULL, 'counterparties', NULL)""",
    "delete": """DELETE FROM order_items WHERE order_id IN (2, 3);
DELETE FROM comments WHERE (owner_kind = 'order' AND owner_id IN (2, 3))
                        OR (owner_kind = 'counterparty' AND owner_id IN (2, 3));
ALTER TABLE orders DISABLE TRIGGER orders_no_delete;
DELETE FROM orders WHERE id IN (2, 3);
ALTER TABLE orders ENABLE TRIGGER orders_no_delete;
DELETE FROM counterparties WHERE id IN (2, 3);""",
    "files": """UPDATE files SET deleted_at = now() WHERE owner_kind = 'order' AND owner_id IN (2, 3);""",
    "keep": """  ('позиции настоящей заявки', 'SELECT count(*) FROM order_items WHERE order_id = 1', 2),
  ('комментарии настоящей заявки', 'SELECT count(*) FROM comments WHERE owner_kind = ''order'' AND owner_id = 1', 1),
  ('файлы настоящей заявки целы', 'SELECT count(*) FROM files WHERE owner_id = 1 AND deleted_at IS NULL', 1)""",
}

BLOCK = re.compile(r"-- >>> ЗАПОЛНИ: (\w+)\n(.*?)-- <<<", re.DOTALL)


def filled(**override: str) -> str:
    parts = dict(FILL, **override)
    text = TEMPLATE.read_text(encoding="utf-8")
    seen = set()

    def put(m):
        seen.add(m.group(1))
        return f"-- >>> ЗАПОЛНИ: {m.group(1)}\n{parts[m.group(1)]}\n-- <<<"
    text = BLOCK.sub(put, text)
    assert seen == set(FILL), f"в шаблоне блоки {sorted(seen)}, тест знает {sorted(FILL)}"
    return text


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@pytest.fixture
def db(tmp_path: Path):
    data, sock = tmp_path / "data", tmp_path / "sock"
    sock.mkdir()
    port = free_port()
    subprocess.run([NEEDED["initdb"], "-D", str(data), "-U", "kit", "-E", "UTF8", "--locale=C.UTF-8",
                    "-A", "trust"], check=True, capture_output=True)
    subprocess.run([NEEDED["pg_ctl"], "-D", str(data), "-l", str(tmp_path / "pg.log"), "-w",
                    "-o", f"-k {sock} -p {port} -c listen_addresses=''", "start"],
                   check=True, capture_output=True)
    env = dict(os.environ, PGHOST=str(sock), PGPORT=str(port), PGUSER="kit", PGDATABASE="postgres")

    def psql(sql: str = "", file: Path = None) -> subprocess.CompletedProcess:
        # файл гоняется без -q: как у человека, последняя строка COMMIT или ошибка
        args = [NEEDED["psql"], "-X", "-v", "ON_ERROR_STOP=1"]
        args += ["-f", str(file)] if file else ["-q", "-At", "-c", sql]
        return subprocess.run(args, env=env, capture_output=True, text=True, encoding="utf-8")

    done = psql(SCHEMA)
    assert done.returncode == 0, done.stderr
    yield psql, tmp_path
    subprocess.run([NEEDED["pg_ctl"], "-D", str(data), "-m", "immediate", "stop"], capture_output=True)


def snapshot(psql) -> dict:
    out = {}
    for tbl in ("counterparties", "orders", "order_items", "comments", "files"):
        out[tbl] = int(psql(f"SELECT count(*) FROM {tbl}").stdout.strip())
    out["files_deleted"] = int(psql("SELECT count(*) FROM files WHERE deleted_at IS NOT NULL").stdout.strip())
    out["trigger_on"] = psql("SELECT tgenabled FROM pg_trigger WHERE tgname = 'orders_no_delete'").stdout.strip()
    return out


def run_cleanup(psql, tmp_path: Path, sql: str) -> subprocess.CompletedProcess:
    path = tmp_path / "cleanup.sql"
    path.write_text(sql, encoding="utf-8")
    return psql(file=path)


def test_control_pass_commits_and_keeps_the_real(db):
    psql, tmp = db
    done = run_cleanup(psql, tmp, filled())
    assert done.returncode == 0, done.stdout + done.stderr
    assert done.stdout.strip().splitlines()[-1] == "COMMIT"
    after = snapshot(psql)
    assert after == {"counterparties": 1, "orders": 1, "order_items": 2, "comments": 2,
                     "files": 3, "files_deleted": 2, "trigger_on": "O"}
    assert "ссылки в пустоту: до 1, после 1" in done.stderr  # старая сирота не мешает
    assert "ушло 0 (ожидалось 0)" in done.stderr  # ноль печатается, а не пропускается


@pytest.mark.parametrize("override,word", [
    ({"expect": FILL["expect"].replace("('order_items', 4, 2)", "('order_items', 4, 1)")}, "ушло 2, ожидалось 1"),
    ({"names": FILL["names"].replace("'Тест Один'", "'Тест 1'")}, "до первого удаления"),
    ({"expect": FILL["expect"].replace("('orders', 3, 2)", "('orders', 4, 2)")}, "база изменилась"),
    ({"delete": FILL["delete"].replace(
        "DELETE FROM comments WHERE (owner_kind = 'order' AND owner_id IN (2, 3))\n"
        "                        OR (owner_kind = 'counterparty' AND owner_id IN (2, 3));", ""),
      "expect": FILL["expect"].replace("('comments', 4, 2)", "('comments', 4, 0)")}, "новых ссылок в пустоту"),
    ({"keep": FILL["keep"].replace("order_id = 1', 2)", "order_id = 1', 3)")}, "остающееся задето"),
    ({"delete": FILL["delete"].replace("ALTER TABLE orders DISABLE TRIGGER orders_no_delete;\n", "")
                              .replace("ALTER TABLE orders ENABLE TRIGGER orders_no_delete;\n", "")},
     "подтверждённую заявку удалять нельзя"),
    ({"refs": FILL["refs"].replace("'deleted_at IS NULL'", "NULL")}, "новых ссылок в пустоту"),
], ids=["numbers", "wrong-name", "base-changed", "new-orphan", "keep-touched", "trigger", "tombstones-not-excluded"])
def test_any_guard_rolls_everything_back(db, override, word):
    psql, tmp = db
    before = snapshot(psql)
    done = run_cleanup(psql, tmp, filled(**override))
    assert done.returncode != 0, done.stdout + done.stderr
    assert word in done.stderr, done.stderr
    assert "COMMIT" not in done.stdout.split()
    assert snapshot(psql) == before  # откат проверен счётом, а не доверием


def test_wrong_name_stops_before_any_delete(db):
    psql, tmp = db
    done = run_cleanup(psql, tmp, filled(names=FILL["names"].replace("'Тест Один'", "'Тест 1'")))
    assert "ушло" not in done.stderr  # до сверки чисел дело не дошло
    assert "имя сошлось: counterparties.1" in done.stderr
