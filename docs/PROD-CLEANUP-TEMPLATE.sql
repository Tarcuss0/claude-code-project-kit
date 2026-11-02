-- Чистка боевой базы от пробных данных: каркас. Порядок работы и причины: docs/PROD-CLEANUP.md.
--
-- Заполняются только блоки между «-- >>> ЗАПОЛНИ» и «-- <<<». Всё остальное: три сторожа,
-- общие для любой чистки; их не правь.
--
-- Запуск (сначала на копии из свежего дампа, потом на бою, человеком):
--     psql -v ON_ERROR_STOP=1 -d <база> -f cleanup.sql
-- Смотри на последнюю строку. COMMIT: чистка прошла. ERROR: транзакция откатилась целиком,
-- в базе ничего не изменилось. Других исходов нет.
--
-- Имена служебных таблиц латиницей: psql на Windows читает файл в кодировке консоли.

\encoding UTF8
\set ON_ERROR_STOP on

BEGIN;
-- Не ждать бесконечно за живой нагрузкой: не взяли блокировку за 5 секунд, значит отказ.
SET LOCAL lock_timeout = '5s';

-- ============================================================ 1. предметы по имени
-- Номер ничего не доказывает: на другой базе под ним лежит другая запись.
-- Каждый удаляемый предмет и тот, что остаётся: таблица, номер, поле имени, ожидаемое имя.
CREATE TEMP TABLE kit_named(tbl text, id bigint, name_col text, expected text) ON COMMIT DROP;
INSERT INTO kit_named VALUES
-- >>> ЗАПОЛНИ: names
  ('<таблица>', 0, '<поле_имени>', '<ожидаемое имя>')
-- <<<
;

DO $$
DECLARE r record; got text;
BEGIN
  FOR r IN SELECT * FROM kit_named LOOP
    EXECUTE format('SELECT %I::text FROM %s WHERE id = $1', r.name_col, r.tbl::regclass)
      USING r.id INTO got;
    IF got IS DISTINCT FROM r.expected THEN
      RAISE EXCEPTION 'предмет %.% называется «%», ожидалось «%»: чистка остановлена до первого удаления',
        r.tbl, r.id, coalesce(got, 'нет такой записи'), r.expected;
    END IF;
    RAISE NOTICE 'имя сошлось: %.% = «%»', r.tbl, r.id, got;
  END LOOP;
END $$;

-- ============================================================ 2. числа по таблицам
-- Сколько строк было, когда считали, и сколько уйдёт. Сюда же таблицы, которые не должны
-- пострадать, с нулём: явный ноль доказывает, что таблицу смотрели.
CREATE TEMP TABLE kit_expect(tbl text, was bigint, gone bigint) ON COMMIT DROP;
INSERT INTO kit_expect VALUES
-- >>> ЗАПОЛНИ: expect
  ('<таблица>', 0, 0)
-- <<<
;

CREATE TEMP TABLE kit_before(tbl text, n bigint) ON COMMIT DROP;
DO $$
DECLARE r record; n bigint;
BEGIN
  FOR r IN SELECT * FROM kit_expect LOOP
    EXECUTE format('SELECT count(*) FROM %s', r.tbl::regclass) INTO n;
    INSERT INTO kit_before VALUES (r.tbl, n);
    IF n <> r.was THEN
      RAISE EXCEPTION 'таблица %: сейчас % строк, а считали при подготовке %: база изменилась, пересчитай',
        r.tbl, n, r.was;
    END IF;
  END LOOP;
END $$;

-- ============================================================ 3. ссылки в пустоту, «до»
-- Каскад знает только внешние ключи. Здесь перечисляются места без ключа:
-- полиморфные (поле вида + поле номера) и простые ссылки без внешнего ключа (kind_col NULL).
-- target: таблица, где лежит объект этого вида; ключ в ней называется id.
-- live: какие строки считать живыми (NULL: все). Строки, погашенные отметкой, продолжают
-- ссылаться на удалённого владельца; без условия 'deleted_at IS NULL' сторож законно
-- назовёт их новыми сиротами. Исключай их явно, а не убирая таблицу из списка.
CREATE TEMP TABLE kit_refs(tbl text, kind_col text, id_col text, kind text, target text, live text) ON COMMIT DROP;
INSERT INTO kit_refs VALUES
-- >>> ЗАПОЛНИ: refs
  ('<таблица>', '<поле_вида>', '<поле_номера>', '<вид>', '<таблица_объекта>', NULL)
-- <<<
;

CREATE FUNCTION pg_temp.kit_orphans() RETURNS bigint AS $$
DECLARE total bigint := 0; n bigint; r record;
BEGIN
  FOR r IN SELECT * FROM kit_refs LOOP
    IF r.kind_col IS NULL THEN
      EXECUTE format('SELECT count(*) FROM %s t WHERE t.%I IS NOT NULL AND (%s)
                        AND NOT EXISTS (SELECT 1 FROM %s o WHERE o.id = t.%I)',
                     r.tbl::regclass, r.id_col, coalesce(r.live, 'true'), r.target::regclass, r.id_col) INTO n;
    ELSE
      EXECUTE format('SELECT count(*) FROM %s t WHERE t.%I = $1 AND (%s)
                        AND NOT EXISTS (SELECT 1 FROM %s o WHERE o.id = t.%I)',
                     r.tbl::regclass, r.kind_col, coalesce(r.live, 'true'), r.target::regclass, r.id_col)
        USING r.kind INTO n;
    END IF;
    total := total + n;
  END LOOP;
  RETURN total;
END $$ LANGUAGE plpgsql;

CREATE TEMP TABLE kit_orphans_before ON COMMIT DROP AS SELECT pg_temp.kit_orphans() AS n;

-- ============================================================ 4. удаление, от листьев к корню
-- Если упираешься в триггер, запрещающий удаление, гаси прицельно и внутри транзакции:
--   ALTER TABLE <таблица> DISABLE TRIGGER <имя>;  DELETE ...;  ALTER TABLE <таблица> ENABLE TRIGGER <имя>;
-- Это берёт исключительную блокировку таблицы до конца транзакции. Общий выключатель
-- session_replication_role = replica не используй: он снимает и проверку внешних ключей.
-- >>> ЗАПОЛНИ: delete
-- <<<

-- ============================================================ 5. файлы: отметка вместо удаления
-- Строку файла не удаляем, а гасим отметкой: сборщик мусора хранилища ходит по строкам,
-- удалённая строка оставит объект в хранилище сиротой навсегда.
-- >>> ЗАПОЛНИ: files
-- <<<

-- ============================================================ 6. сверка чисел
-- Печатаются все строки, а не только расхождения: молчание сторожа должно быть видно.
DO $$
DECLARE r record; n bigint;
BEGIN
  FOR r IN SELECT e.tbl, e.gone, b.n AS before FROM kit_expect e JOIN kit_before b USING (tbl) LOOP
    EXECUTE format('SELECT count(*) FROM %s', r.tbl::regclass) INTO n;
    RAISE NOTICE 'таблица %: было %, стало %, ушло % (ожидалось %)', r.tbl, r.before, n, r.before - n, r.gone;
    IF r.before - n <> r.gone THEN
      RAISE EXCEPTION 'таблица %: ушло %, ожидалось %', r.tbl, r.before - n, r.gone;
    END IF;
  END LOOP;
END $$;

-- ============================================================ 7. ссылки в пустоту, «после»
-- Сравнение с «до», а не с нулём: в живой базе сироты от старых удалений обычно уже есть.
DO $$
DECLARE before bigint; after bigint;
BEGIN
  SELECT n INTO before FROM kit_orphans_before;
  after := pg_temp.kit_orphans();
  RAISE NOTICE 'ссылки в пустоту: до %, после %', before, after;
  IF after > before THEN
    RAISE EXCEPTION 'чистка оставила % новых ссылок в пустоту', after - before;
  END IF;
END $$;

-- ============================================================ 8. то, что остаётся, цело по содержимому
-- «Одна заявка осталась» не говорит, что от неё осталось. Запрос возвращает одно число.
CREATE TEMP TABLE kit_keep(label text, query text, expected bigint) ON COMMIT DROP;
INSERT INTO kit_keep VALUES
-- >>> ЗАПОЛНИ: keep
  ('<что проверяем>', 'SELECT count(*) FROM <таблица> WHERE <условие>', 0)
-- <<<
;

DO $$
DECLARE r record; n bigint;
BEGIN
  FOR r IN SELECT * FROM kit_keep LOOP
    EXECUTE r.query INTO n;
    RAISE NOTICE 'остаётся: % = % (ожидалось %)', r.label, n, r.expected;
    IF n IS DISTINCT FROM r.expected THEN
      RAISE EXCEPTION 'остающееся задето: % = %, ожидалось %', r.label, n, r.expected;
    END IF;
  END LOOP;
END $$;

COMMIT;
