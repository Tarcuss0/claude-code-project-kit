# Общие функции для pull-backup.ps1, bundle-repos.ps1 и install-backup-task.ps1.
# Подключается через dot-source: . (Join-Path $PSScriptRoot 'lib-backup.ps1')
# Здесь только функции без побочных эффектов на сервер: их можно проверять без сети
# (tests/lib-backup.tests.ps1). Файл сохранён как UTF-8 with BOM.

function Read-Conf {
    # KEY=VALUE построчно. Пустые строки и строки с # пропускаются.
    # Значения читаются как есть: ; и \ (пути Windows) не интерпретируются.
    param([string]$Path)
    $h = @{}
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $i = $t.IndexOf('=')
        if ($i -gt 0) { $h[$t.Substring(0, $i).Trim()] = $t.Substring($i + 1).Trim() }
    }
    return $h
}

function Write-Utf8NoBom {
    # Метки читает Python на сервере: BOM в начале файла ему мешает.
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-StampDate {
    # Имя каталога yyyyMMdd-HHmmss это момент снятия по UTC на сервере.
    param([string]$Stamp)
    $style = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    return [datetime]::ParseExact($Stamp, 'yyyyMMdd-HHmmss', [System.Globalization.CultureInfo]::InvariantCulture, $style)
}

function Get-StampAgeHours {
    param([string]$Stamp, [datetime]$Now = (Get-Date).ToUniversalTime())
    return [math]::Round(($Now.ToUniversalTime() - (Get-StampDate $Stamp)).TotalHours, 1)
}

function Read-RemoteListing {
    # Разбор ответа сервера: строка DIR=<имя>/ и строки «<sha256>  ./<файл>».
    # Принимаются только строки с настоящей суммой (64 hex): предупреждения ssh
    # вроде «Warning: Permanently added ...» файлами не считаются.
    # Отказ, если каталога нет, он пуст или в нём нет отметки полноты.
    param([string[]]$Lines, [string]$Marker = 'OK')

    $stamp = ''
    $files = @{}
    foreach ($line in $Lines) {
        $text = "$line".Trim()
        if (-not $text) { continue }
        if ($text.StartsWith('DIR=')) {
            $stamp = $text.Substring(4).TrimEnd('/')
            continue
        }
        $parts = $text -split '\s+', 2
        if ($parts.Count -ne 2) { continue }
        if ($parts[0] -notmatch '^[0-9a-fA-F]{64}$') { continue }
        $name = $parts[1].Trim()
        if ($name.StartsWith('./')) { $name = $name.Substring(2) }
        $files[$name] = $parts[0].ToLower()
    }

    if (-not $stamp) { throw 'сервер не назвал каталог копии: пусто в каталоге снимков?' }
    if ($files.Count -eq 0) { throw "каталог $stamp на сервере пуст" }
    if (-not $files.ContainsKey($Marker)) {
        throw "в копии $stamp нет отметки ${Marker}: снятие не дошло до конца, такое не забираем"
    }
    return [pscustomobject]@{ Stamp = $stamp; Files = $files }
}

function Test-CopyIntact {
    # Сверка содержимого, а не факта «scp вернул ноль». В обе стороны:
    #   нет файла    - недокачанный набор;
    #   сумма другая - файл доехал повреждённым;
    #   лишний файл  - это не тот каталог, что назвал сервер.
    # Возвращает список бед строками; пустой список означает, что всё сошлось.
    param([hashtable]$Expected, [string]$Directory)

    $problems = @()
    foreach ($name in ($Expected.Keys | Sort-Object)) {
        $path = Join-Path $Directory $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $problems += "$name - файла нет вовсе"
            continue
        }
        $mine = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower()
        if ($mine -ne $Expected[$name]) {
            $problems += "$name - сумма разошлась (сервер $($Expected[$name].Substring(0,12)), у нас $($mine.Substring(0,12)))"
        }
    }

    $prefix = (Resolve-Path -LiteralPath $Directory).Path
    foreach ($item in (Get-ChildItem -LiteralPath $Directory -Recurse -File)) {
        $name = $item.FullName.Substring($prefix.Length).TrimStart('\', '/').Replace('\', '/')
        if (-not $Expected.ContainsKey($name)) {
            $problems += "$name - лишний файл, сервер его не называл"
        }
    }
    return $problems
}

function Remove-OldCopies {
    # Чистка локальных снимков по возрасту.
    #  - Удаляются только свои каталоги: имя yyyyMMdd-HHmmss И внутри лежит $Core.
    #  - Возраст считается по имени каталога, а не по времени файла: копирование
    #    и перенос ставят свою дату.
    #  - Первые $AtLeast снимков не удаляются при любом возрасте: машина могла быть
    #    выключена месяцами, и чистка по сроку иначе снесла бы единственную копию.
    # Возвращает имена удалённых.
    param(
        [string]$Store,
        [int]$Days,
        [int]$AtLeast,
        [string]$Core = 'database.dump',
        [datetime]$Now = (Get-Date).ToUniversalTime()
    )

    $mine = @(Get-ChildItem -LiteralPath $Store -Directory |
              Where-Object { $_.Name -match '^\d{8}-\d{6}$' } |
              Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName $Core) -PathType Leaf } |
              Sort-Object Name -Descending)

    if ($mine.Count -le $AtLeast) { return @() }

    $edge = $Now.ToUniversalTime().AddDays(-$Days)
    $removed = @()
    foreach ($dir in $mine[$AtLeast..($mine.Count - 1)]) {
        if ((Get-StampDate $dir.Name) -lt $edge) {
            Remove-Item -LiteralPath $dir.FullName -Recurse -Force
            $removed += $dir.Name
        }
    }
    return $removed
}

function Invoke-Native {
    # Запуск ssh/scp/git. В Windows PowerShell 5.1 запись нативной команды в stderr
    # при $ErrorActionPreference = 'Stop' становится ошибкой, хотя команда отработала.
    # Здесь режим временно 'Continue', а успех решается кодом возврата.
    param([scriptblock]$Block)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = @(& $Block 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $old }
    return [pscustomobject]@{ Output = $out; Code = $code }
}
