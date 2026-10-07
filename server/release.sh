#!/usr/bin/env bash
# Приём и откат релиза на сервере. Один файл, две команды:
#
#   release.sh --root <каталог> receive <имя>.tgz   принять архив из <каталог>/incoming
#   release.sh --root <каталог> rollback [<релиз>]  вернуться на прежний релиз
#
# Что делает receive:
#   1. проверяет имя и содержимое архива, распаковывает в releases/<имя> (через .part);
#   2. PRE_SWITCH_CMD в каталоге нового релиза (например миграции). Не прошла: симлинк
#      не тронут, релиз удалён, прод остаётся на прежнем;
#   3. переключает симлинк current на новый релиз (атомарно) и вызывает RESTART_CMD;
#   4. ждёт ответа 200 от HEALTH_URL до HEALTH_WAIT секунд;
#   5. не дождался: возвращает симлинк на прежний релиз, снова RESTART_CMD, выход 1;
#   6. дождался: чистит старые релизы (остаётся KEEP_RELEASES), печатает «ОК».
#
# Настройки лежат в <каталог>/release.env (пример: server/release.env.example), строки
# KEY=VALUE. Файл не исполняется как shell, читаются только известные ключи.
#
# Откат возвращает КОД. Схему базы он не трогает: поэтому миграции только аддитивные.
set -euo pipefail

die() { echo "release: $*" >&2; exit 1; }
log() { echo "release: $*"; }

ROOT=""
if [ "${1:-}" = "--root" ]; then
    ROOT="${2:-}"
    shift 2 || true
fi
CMD="${1:-}"
[ $# -gt 0 ] && shift
[ -n "$ROOT" ] && [ -d "$ROOT" ] || die "нужен --root <существующий каталог>"
ROOT=$(cd "$ROOT" && pwd)
CONF="$ROOT/release.env"

conf_get() {
    local key=$1 default=${2-} line
    if [ -f "$CONF" ]; then
        line=$(grep -E "^[[:space:]]*${key}=" "$CONF" | tail -n 1 || true)
        if [ -n "$line" ]; then
            printf '%s' "${line#*=}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
            return
        fi
    fi
    printf '%s' "$default"
}

INCOMING=$(conf_get INCOMING "$ROOT/incoming")
RELEASES=$(conf_get RELEASES "$ROOT/releases")
CURRENT=$(conf_get CURRENT "$ROOT/current")
KEEP_RELEASES=$(conf_get KEEP_RELEASES 5)
PRE_SWITCH_CMD=$(conf_get PRE_SWITCH_CMD "")
RESTART_CMD=$(conf_get RESTART_CMD "")
HEALTH_URL=$(conf_get HEALTH_URL "")
HEALTH_WAIT=$(conf_get HEALTH_WAIT 60)
HEALTH_INTERVAL=$(conf_get HEALTH_INTERVAL 2)

[[ "$KEEP_RELEASES" =~ ^[0-9]+$ ]] && [ "$KEEP_RELEASES" -ge 2 ] || die "KEEP_RELEASES должен быть числом не меньше 2 (текущий и прежний нужны для отката)"
[[ "$HEALTH_WAIT" =~ ^[0-9]+$ ]] || die "HEALTH_WAIT должен быть числом секунд"

command -v flock >/dev/null || die "нет flock"
mkdir -p "$INCOMING" "$RELEASES"
exec 9>"$ROOT/.release.lock"
flock -n 9 || die "уже идёт другой приём или откат"

switch_to() {
    # Атомарно: новый симлинк рядом, потом rename поверх старого.
    ln -sfn "$1" "$CURRENT.new"
    mv -T "$CURRENT.new" "$CURRENT"
}

restart() {
    [ -n "$RESTART_CMD" ] || return 0
    ( cd "$CURRENT" && RELEASE_DIR=$(readlink -f "$CURRENT") bash -c "$RESTART_CMD" )
}

wait_health() {
    if [ -z "$HEALTH_URL" ]; then
        log "HEALTH_URL не задан: проверка здоровья пропущена"
        return 0
    fi
    command -v curl >/dev/null || die "нет curl для проверки $HEALTH_URL"
    local deadline=$(( $(date +%s) + HEALTH_WAIT ))
    while :; do
        if curl -fsS -m 5 -o /dev/null "$HEALTH_URL" 2>/dev/null; then
            return 0
        fi
        if [ "$(date +%s)" -ge "$deadline" ]; then
            return 1
        fi
        sleep "$HEALTH_INTERVAL"
    done
}

candidates() {
    # Релизы по возрастанию имени (в имени штамп yyyymmdd-HHMMSS фиксированной длины).
    find "$RELEASES" -mindepth 1 -maxdepth 1 -type d ! -name '.*' ! -name '*.failed' -printf '%f\n' | sort
}

current_release() {
    if [ -L "$CURRENT" ]; then
        readlink -f "$CURRENT"
    fi
}

cmd_receive() {
    local name=${1:-}
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.tgz$ ]] || die "недопустимое имя архива: '$name'"
    local archive="$INCOMING/$name"
    [ -f "$archive" ] || die "нет архива $archive"

    local rel_name=${name%.tgz}
    local rel="$RELEASES/$rel_name"
    [ ! -e "$rel" ] && [ ! -e "$rel.failed" ] || die "релиз $rel_name уже есть: у каждого релиза своё имя"

    local listing
    listing=$(tar -tzf "$archive") || die "архив не читается: $name"
    if grep -qE '(^|/)\.\.(/|$)|^/' <<<"$listing"; then
        die "в архиве абсолютные пути или '..': не принимаю"
    fi

    local part="$RELEASES/.$rel_name.part"
    rm -rf "$part"
    mkdir -p "$part"
    if ! tar -xzf "$archive" -C "$part" --no-same-owner; then
        rm -rf "$part"
        die "архив не распаковался, прод не тронут"
    fi
    mv "$part" "$rel"
    log "распаковано: $rel_name"

    local prev
    prev=$(current_release || true)

    if [ -n "$PRE_SWITCH_CMD" ]; then
        log "подготовка: $PRE_SWITCH_CMD"
        if ! ( cd "$rel" && RELEASE_DIR="$rel" bash -c "$PRE_SWITCH_CMD" ); then
            rm -rf "$rel"
            die "подготовка не прошла, симлинк не тронут, прод на прежнем релизе"
        fi
    fi

    local ok=1
    switch_to "$rel"
    log "переключено на $rel_name"
    if ! restart; then
        log "RESTART_CMD завершился с ошибкой"
        ok=0
    elif ! wait_health; then
        log "здоровье не подтвердилось за ${HEALTH_WAIT} с: $HEALTH_URL"
        ok=0
    fi

    if [ "$ok" -eq 0 ]; then
        mv "$rel" "$rel.failed"
        if [ -n "$prev" ] && [ -d "$prev" ]; then
            switch_to "$prev"
            log "откат на $(basename "$prev")"
            restart || log "ВНИМАНИЕ: перезапуск после отката тоже не прошёл, смотри сервис руками"
            if wait_health; then
                die "новый релиз не поднялся, прод вернулся на $(basename "$prev"). Разбор: $rel.failed"
            fi
            die "новый релиз не поднялся, и прежний после отката не отвечает. Нужны руки. Разбор: $rel.failed"
        fi
        die "новый релиз не поднялся, откатываться некуда (это первый релиз). Разбор: $rel.failed"
    fi

    prune "$rel"
    log "ОК $rel_name живой"
}

prune() {
    local keep_dir=$1
    local all=()
    mapfile -t all < <(candidates)
    local total=${#all[@]}
    local n
    if [ "$total" -gt "$KEEP_RELEASES" ]; then
        for n in "${all[@]:0:total-KEEP_RELEASES}"; do
            if [ "$RELEASES/$n" = "$keep_dir" ]; then
                continue
            fi
            rm -rf "${RELEASES:?}/$n"
        done
    fi

    # Неудавшиеся релизы нужны для разбора: оставляем два последних.
    local failed=()
    mapfile -t failed < <(find "$RELEASES" -mindepth 1 -maxdepth 1 -type d -name '*.failed' -printf '%f\n' | sort)
    if [ "${#failed[@]}" -gt 2 ]; then
        for n in "${failed[@]:0:${#failed[@]}-2}"; do
            rm -rf "${RELEASES:?}/$n"
        done
    fi

    # Архив в incoming нужен, пока жив его релиз (или разбор неудачного).
    local archive base
    for archive in "$INCOMING"/*.tgz; do
        [ -e "$archive" ] || continue
        base=$(basename "$archive" .tgz)
        if [ ! -d "$RELEASES/$base" ] && [ ! -d "$RELEASES/$base.failed" ]; then
            rm -f "$archive"
        fi
    done
}

cmd_rollback() {
    local target=${1:-}
    local cur cur_name
    cur=$(current_release || true)
    [ -n "$cur" ] || die "current не указывает ни на какой релиз: откатывать нечего"
    cur_name=$(basename "$cur")

    if [ -z "$target" ]; then
        local all=() n
        mapfile -t all < <(candidates)
        for n in "${all[@]}"; do
            if [ "$n" = "$cur_name" ]; then
                break
            fi
            target=$n
        done
        [ -n "$target" ] || die "прежнего релиза нет: сейчас самый старый из оставшихся ($cur_name)"
    fi
    [[ "$target" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "недопустимое имя релиза: '$target'"
    [ -d "$RELEASES/$target" ] || die "нет релиза $target"
    [ "$target" != "$cur_name" ] || die "это и есть текущий релиз"

    switch_to "$RELEASES/$target"
    log "переключено на $target (было $cur_name)"
    restart || die "перезапуск после отката не прошёл, смотри сервис руками"
    if wait_health; then
        log "ОК откат на $target, здоровье подтверждено. Схема базы осталась новой."
    else
        die "откат на $target выполнен, но здоровье не подтвердилось. Нужны руки."
    fi
}

case "$CMD" in
    receive)  cmd_receive "$@" ;;
    rollback) cmd_rollback "$@" ;;
    *) die "использование: release.sh --root <каталог> receive <имя>.tgz | rollback [<релиз>]" ;;
esac
