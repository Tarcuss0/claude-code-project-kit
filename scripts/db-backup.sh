#!/usr/bin/env bash
# PostgreSQL backup on the server. Run from cron, e.g. 30 0 * * * (server time, usually UTC).
#
# Layout: <SERVER_BACKUP_DIR>/db/daily/<yyyymmdd-HHMMSS>/{database.dump,OK}
# A snapshot directory becomes visible only when it is complete: the dump is written into a
# hidden .part directory, checked, marked with OK, and then renamed. The PC side (pull-backup.ps1)
# takes only directories that contain OK, so a half-written snapshot is never copied.
#
# Keeps KEEP_DAILY daily and KEEP_WEEKLY weekly snapshots and writes <SERVER_STATE_DIR>/last-dump.json.
# Settings come from scripts/project.conf (KEY=VALUE lines); DATABASE_URL comes from the project .env.
# Any setting can also be passed as an environment variable and wins over the file.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${CONF:-$SCRIPT_DIR/project.conf}"

# Читаем только нужные ключи, а не source всего файла:
# в конфиге есть значения с ; и \ (пути Windows), которые bash принял бы за команды.
conf_get() {
  local key="$1" default="${2:-}" val
  if [ -n "${!key:-}" ]; then printf '%s' "${!key}"; return; fi
  if [ -f "$CONF" ]; then
    val="$(grep -E "^${key}=" "$CONF" | head -n 1 | cut -d= -f2- | tr -d '\r' || true)"
    if [ -n "$val" ]; then printf '%s' "$val"; return; fi
  fi
  printf '%s' "$default"
}

die() { echo "$(date -u +%FT%TZ) ОШИБКА: $*" >&2; exit 1; }

ENV_FILE="$(conf_get SERVER_ENV_FILE)"
BACKUP_ROOT="$(conf_get SERVER_BACKUP_DIR)"
STATE_DIR="$(conf_get SERVER_STATE_DIR)"
DB_SCHEMAS="$(conf_get DB_SCHEMAS)"
KEEP_DAILY="$(conf_get KEEP_DAILY 7)"
KEEP_WEEKLY="$(conf_get KEEP_WEEKLY 4)"
PG_IMAGE="$(conf_get PG_IMAGE postgres:16)"
PG_MAX_MAJOR="$(conf_get PG_MAX_MAJOR 16)"

[ -n "$ENV_FILE" ] || die "SERVER_ENV_FILE не задан"
[ -n "$BACKUP_ROOT" ] || die "SERVER_BACKUP_DIR не задан"
[ -n "$STATE_DIR" ] || die "SERVER_STATE_DIR не задан"
DAILY_DIR="$BACKUP_ROOT/db/daily"
WEEKLY_DIR="$BACKUP_ROOT/db/weekly"

command -v docker >/dev/null || die "docker не найден"
command -v python3 >/dev/null || die "python3 не найден"
[ -f "$ENV_FILE" ] || die "нет файла $ENV_FILE"

mkdir -p "$DAILY_DIR" "$WEEKLY_DIR" "$STATE_DIR"
# Остатки прошлых оборванных запусков
rm -rf "$DAILY_DIR"/.*.part 2>/dev/null || true

# Параметры соединения берём из DATABASE_URL целиком: второго места хранения пароля нет.
CONN="$(python3 "$SCRIPT_DIR/dburl.py" "$ENV_FILE")" || die "не удалось разобрать DATABASE_URL"
IFS="|" read -r DB_USER DB_PASS DB_HOST DB_PORT DB_NAME <<<"$CONN"
[ -n "$DB_USER$DB_HOST$DB_NAME" ] || die "пустые параметры соединения"

run_pg() {
  # --network host: база может слушать только внутренний адрес сервера
  docker run --rm --network host -e PGPASSWORD="$DB_PASS" "$PG_IMAGE" "$@"
}

# Версия сервера БД не должна быть новее клиента в образе: иначе дамп неполный или пустой.
SRV_VER="$(run_pg psql -U "$DB_USER" -h "$DB_HOST" -p "$DB_PORT" -d "$DB_NAME" -At -c "SHOW server_version_num" 2>&1)" \
  || die "база $DB_HOST:$DB_PORT/$DB_NAME недоступна. Ответ psql: $SRV_VER"
SRV_MAJOR=$(( SRV_VER / 10000 ))
[ "$SRV_MAJOR" -le "$PG_MAX_MAJOR" ] || die "сервер БД версии $SRV_MAJOR новее клиента $PG_MAX_MAJOR: поменяй PG_IMAGE"

SCHEMA_ARGS=()
if [ -n "$DB_SCHEMAS" ]; then
  IFS=',' read -ra SCHEMAS <<<"$DB_SCHEMAS"
  for s in "${SCHEMAS[@]}"; do SCHEMA_ARGS+=(-n "$s"); done
fi

STAMP="$(date -u +%Y%m%d-%H%M%S)"
PART="$DAILY_DIR/.$STAMP.part"
FINAL="$DAILY_DIR/$STAMP"
mkdir -p "$PART"
DUMP="$PART/database.dump"

# Текст ошибки pg_dump остаётся в выводе целиком
if ! run_pg pg_dump -U "$DB_USER" -h "$DB_HOST" -p "$DB_PORT" -d "$DB_NAME" -Fc ${SCHEMA_ARGS[@]+"${SCHEMA_ARGS[@]}"} >"$DUMP"; then
  rm -rf "$PART"
  die "pg_dump завершился с ошибкой"
fi

SIZE="$(stat -c %s "$DUMP")"
[ "$SIZE" -gt 1024 ] || { rm -rf "$PART"; die "дамп подозрительно маленький ($SIZE байт)"; }

# Дамп должен открываться: читаем оглавление
if ! docker run --rm -i "$PG_IMAGE" pg_restore --list <"$DUMP" >/dev/null 2>&1; then
  rm -rf "$PART"
  die "дамп не открывается через pg_restore --list"
fi

# Отметка полноты пишется последней, и только потом каталог получает видимое имя
printf '%s %s\n' "$(date -u +%FT%TZ)" "$SIZE" >"$PART/OK"
mv "$PART" "$FINAL"

# Воскресенье: копия снимка в недельные
if [ "$(date -u +%u)" = "7" ]; then
  cp -a "$FINAL" "$WEEKLY_DIR/$STAMP"
fi

# Ротация по имени каталога: трогаем только каталоги вида yyyymmdd-HHMMSS
rotate() {
  local dir="$1" keep="$2" name
  find "$dir" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended -regex '.*/[0-9]{8}-[0-9]{6}' -printf '%f\n' \
    | sort -r | tail -n +$((keep + 1)) \
    | while read -r name; do rm -rf -- "${dir:?}/$name"; done
}
rotate "$DAILY_DIR" "$KEEP_DAILY"
rotate "$WEEKLY_DIR" "$KEEP_WEEKLY"

# Метка для /status и тревоги. Без BOM, чтобы Python читал без обработки.
printf '{"finished_at":"%s","snapshot":"%s","bytes":%s}\n' "$(date -u +%FT%TZ)" "$STAMP" "$SIZE" >"$STATE_DIR/last-dump.json"

echo "$(date -u +%FT%TZ) готово: $STAMP, $SIZE байт, метка $STATE_DIR/last-dump.json"
