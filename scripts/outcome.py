# -*- coding: utf-8 -*-
"""Один разбор исхода прогона pytest на все зонды.

Зачем. Когда каждая сессия разбирает вывод сама, каждая ошибается по-своему:
«12 прошли, 2 ошибки» называют зелёным, отказ окружения называют краснотой,
не узнают упавший тест в выводе и докладывают, что подлог «не покраснел».
Этот скрипт различает четыре вещи и называет их разными словами:

  ЗЕЛЁНЫЙ        все собранные тесты прошли;
  НЕ ПРОШЛА      хотя бы одна мера не прошла (FAILED);
  НЕ СОСТОЯЛАСЬ  часть мер не состоялась: ошибка установки или разборки
                 (ERROR), пропуск (SKIPPED), известный дефект (XFAIL),
                 неожиданный успех известного дефекта (XPASS);
  НЕ ДОШЁЛ       прогон не дошёл до мер: ошибка сбора, прерывание,
                 нет итоговой строки, не собрано ни одного теста.

Если есть и «не прошла», и «не состоялась», итог «НЕ ПРОШЛА», а число
не состоявшихся печатается отдельной строкой.

На чём стоит разбор. Только на строках отдельных тестов из сводки `-rA`
(PASSED, FAILED, ERROR, SKIPPED, XFAIL, XPASS). Код выхода pytest не довод:
conftest может вернуть единицу за пропущенный файл при нуле упавших, а ноль
бывает у прогона, где ничего не собралось. Отчёт XML тоже не годится:
в нём XPASS выглядит как обычный успех.

Сверка. Счёт по строкам обязан совпасть с итоговой строкой pytest
(«1 failed, 3 passed, 2 skipped in 0.4s»). Если не совпал (зонд позвал pytest
без `-rA`, вывод обрезан) или в итоге есть вид, которого разбор не знает,
разбор отказывается словами и ничего не угадывает.

Запуск:
    python scripts/outcome.py run -- tests/test_x.py -q
        запустить pytest (сам добавит -rA), напечатать вывод и исход
    python scripts/outcome.py parse <файл-с-выводом>     (или «-» для stdin)
        разобрать уже сохранённый вывод
    python scripts/outcome.py run --expect-red tests/test_x.py::test_y -- tests/test_x.py
        подлог: да, только если этот тест упал именно как FAILED

Код выхода самого скрипта: 0 ЗЕЛЁНЫЙ (или подлог покраснел), 1 НЕ ПРОШЛА,
2 НЕ СОСТОЯЛАСЬ, 3 НЕ ДОШЁЛ, 4 разбор отказался, 5 подлог не покраснел
или не состоялся. Слово исхода печатается всегда: читай его, а не код.
"""
import os
import re
import subprocess
import sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

GREEN, NOT_PASSED, NOT_HELD, NOT_REACHED, REFUSED, PROBE_FAILED = 0, 1, 2, 3, 4, 5
WORD = {
    GREEN: "ЗЕЛЁНЫЙ",
    NOT_PASSED: "НЕ ПРОШЛА",
    NOT_HELD: "НЕ СОСТОЯЛАСЬ",
    NOT_REACHED: "НЕ ДОШЁЛ",
    REFUSED: "РАЗБОР ОТКАЗАЛСЯ",
}

ANSI = re.compile(r"\x1b\[[0-9;]*m")
# Итог pytest: «1 failed, 2 passed, 1 warning in 0.03s», в рамке из «=» или без.
SUMMARY = re.compile(r"^=*\s*((?:\d+ [a-z]+(?:, )?)+) in [\d.]+s\b")
NO_TESTS = re.compile(r"^=*\s*no tests ran in [\d.]+s\b")
PART = re.compile(r"(\d+) ([a-z]+)")
# Виды из итоговой строки, которые разбор понимает, и куда их относить.
KNOWN = {
    "passed": "passed", "failed": "failed",
    "error": "error", "errors": "error",
    "skipped": "skipped", "xfailed": "xfail", "xpassed": "xpass",
    "deselected": "deselected", "warning": None, "warnings": None,
}
# Имя теста: путь::имя и, у параметризованных, [параметры], где бывают пробелы («[a b.tgz]»).
LINE = re.compile(r"^(PASSED|FAILED|ERROR|XFAIL|XPASS) ([^\s\[]+(?:\[[^\]]*\])?\S*)(?: - (.*))?$")
SKIP_LINE = re.compile(r"^SKIPPED \[(\d+)\] (.*)$")


class Parsed:
    def __init__(self):
        self.tests = {"passed": [], "failed": [], "error": [], "xfail": [], "xpass": []}
        self.skipped = []          # (число, «файл:строка: причина»)
        self.collection_errors = []
        self.summary = None        # {вид: число} из итоговой строки
        self.no_tests = False
        self.interrupted = False
        self.stopped_early = False  # -x или --maxfail: после падения остальное не запускалось
        self.refusal = ""

    @property
    def skipped_count(self) -> int:
        return sum(n for n, _ in self.skipped)


def parse(text: str) -> Parsed:
    got = Parsed()
    for raw in text.splitlines():
        line = ANSI.sub("", raw).rstrip()
        if line.startswith("!!!") and "stopping after" in line:
            got.stopped_early = True
        elif "Interrupted:" in line or (line.startswith("!!!") and "nterrupt" in line):
            got.interrupted = True
        m = LINE.match(line)
        if m:
            kind, nodeid, reason = m.group(1), m.group(2), m.group(3) or ""
            if kind == "ERROR" and "::" not in nodeid:
                got.collection_errors.append(nodeid)
            else:
                got.tests[kind.lower()].append((nodeid, reason))
            continue
        m = SKIP_LINE.match(line)
        if m:
            got.skipped.append((int(m.group(1)), m.group(2)))
            continue
        if NO_TESTS.match(line):
            got.no_tests = True
            continue
        m = SUMMARY.match(line)
        if m:
            counts = {}
            for number, kind in PART.findall(m.group(1)):
                if kind not in KNOWN:
                    got.refusal = (f"в итоге pytest есть «{number} {kind}», разбор такого вида не знает "
                                   "и не угадывает: допиши его в outcome.py")
                    return got
                if KNOWN[kind]:
                    counts[KNOWN[kind]] = counts.get(KNOWN[kind], 0) + int(number)
            got.summary = counts
    return got


def verdict(got: Parsed) -> tuple:
    """(код, строки отчёта)."""
    lines = []
    if got.refusal:
        return REFUSED, [got.refusal]
    if got.collection_errors:
        lines.append(f"ошибка сбора, прогон оборван до мер: {', '.join(got.collection_errors)}")
        return NOT_REACHED, lines
    if got.interrupted:
        return NOT_REACHED, ["прогон прерван (Interrupted), часть мер не запускалась"]
    if got.no_tests:
        return NOT_REACHED, ["не собрано ни одного теста (no tests ran)"]
    if got.summary is None:
        return NOT_REACHED, ["нет итоговой строки pytest: прогон упал или вывод обрезан"]

    by_lines = {k: len(v) for k, v in got.tests.items()}
    by_lines["skipped"] = got.skipped_count
    by_lines["error"] += len(got.collection_errors)
    mismatch = [
        f"{kind}: в итоге {got.summary.get(kind, 0)}, строк {by_lines[kind]}"
        for kind in ("passed", "failed", "error", "skipped", "xfail", "xpass")
        if got.summary.get(kind, 0) != by_lines[kind]
    ]
    if mismatch:
        return REFUSED, ["построчный вывод не сходится с итогом pytest, исход не назван "
                         "(позови pytest с -rA и не обрезай вывод): " + "; ".join(mismatch)]

    total = sum(by_lines.values())
    if total == 0:
        return NOT_REACHED, ["тестов в выводе нет, а итог есть: всё отобрано мимо (deselected)?"]

    held_out = by_lines["error"] + by_lines["skipped"] + by_lines["xfail"] + by_lines["xpass"]
    lines.append(f"прошли {by_lines['passed']}, не прошли {by_lines['failed']}, "
                 f"не состоялись {held_out} из {total}")
    if got.stopped_early:
        lines.append("прогон остановлен после падения (-x или --maxfail): остальные меры не запускались")
    if got.summary.get("deselected"):
        lines.append(f"отобраны мимо (-k, -m): {got.summary['deselected']}, их здесь не мерили")
    for nodeid, reason in got.tests["failed"]:
        lines.append(f"  не прошла      {nodeid}  {reason}".rstrip())
    for nodeid, reason in got.tests["error"]:
        lines.append(f"  не состоялась  {nodeid}  ошибка установки или разборки: {reason}".rstrip())
    for count, where in got.skipped:
        lines.append(f"  не состоялась  пропуск ×{count}: {where}")
    for nodeid, reason in got.tests["xfail"]:
        lines.append(f"  не состоялась  {nodeid}  известный дефект (xfail): {reason}".rstrip())
    for nodeid, reason in got.tests["xpass"]:
        lines.append(f"  не состоялась  {nodeid}  xfail неожиданно прошёл, сними пометку: {reason}".rstrip())

    if by_lines["failed"]:
        return NOT_PASSED, lines
    if held_out:
        return NOT_HELD, lines
    return GREEN, lines


def same_test(wanted: str, printed: str) -> bool:
    """tests/test_x.py::test_y совпадает и сам с собой, и с хвостом пути."""
    wanted = wanted.replace("\\", "/")
    printed = printed.replace("\\", "/")
    return printed == wanted or printed.endswith("/" + wanted) or wanted.endswith("/" + printed)


def probe(got: Parsed, code: int, wanted: str) -> tuple:
    """Подлог: тест обязан упасть именно как FAILED. Всё прочее не краснота."""
    if code in (REFUSED, NOT_REACHED):
        return PROBE_FAILED, [f"подлог не состоялся: прогон {WORD[code]}, до теста {wanted} дело не дошло"]
    for kind, word in (("failed", None), ("passed", "прошёл: подлог не покраснел"),
                       ("error", "ERROR, мера не состоялась: это не краснота"),
                       ("xfail", "XFAIL: падение помечено как ожидаемое, это не краснота"),
                       ("xpass", "XPASS: подлог не покраснел")):
        for nodeid, _ in got.tests[kind]:
            if same_test(wanted, nodeid):
                if word is None:
                    return GREEN, [f"подлог покраснел: {nodeid} не прошёл"]
                return PROBE_FAILED, [f"{nodeid}: {word}"]
    return PROBE_FAILED, [f"тест {wanted} в выводе не найден: он не запускался, был пропущен "
                          "или имя записано иначе. Подлог не состоялся"]


def report(code: int, lines: list, title: str = "Исход") -> None:
    print()
    print(f"{title}: {WORD.get(code, 'ПОДЛОГ НЕ ПОКРАСНЕЛ' if code == PROBE_FAILED else '')}")
    for line in lines:
        print("  " + line)


def main(argv: list) -> int:
    expect = None
    if "--expect-red" in argv:
        i = argv.index("--expect-red")
        if i + 1 >= len(argv):
            print("ОТКАЗ: после --expect-red нужен идентификатор теста")
            return REFUSED
        expect = argv[i + 1]
        argv = argv[:i] + argv[i + 2:]

    if argv[:1] == ["parse"] and len(argv) == 2:
        if argv[1] == "-":
            text = sys.stdin.read()
        else:
            with open(argv[1], encoding="utf-8", errors="replace") as f:
                text = f.read()
    elif argv[:1] == ["run"]:
        args = argv[1:]
        if args[:1] == ["--"]:
            args = args[1:]
        env = dict(os.environ, PYTHONIOENCODING="utf-8")
        done = subprocess.run(
            [sys.executable, "-m", "pytest", "-rA", "--color=no", *args],
            capture_output=True, text=True, encoding="utf-8", errors="replace", env=env,
        )
        text = (done.stdout or "") + (done.stderr or "")
        print(text.rstrip())
        print(f"\n(код выхода pytest {done.returncode}: печатается для справки, в исход не входит)")
    else:
        print(__doc__)
        return REFUSED

    got = parse(text)
    code, lines = verdict(got)
    report(code, lines)
    if expect is not None:
        pcode, plines = probe(got, code, expect)
        if pcode == GREEN:
            report(GREEN, plines, "Подлог")
            print("Подлог: ПОКРАСНЕЛ")
            return GREEN
        report(PROBE_FAILED, plines, "Подлог")
        return PROBE_FAILED
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
