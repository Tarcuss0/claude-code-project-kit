# Забор свежего снимка базы с сервера на ПК.
#
#   .\scripts\pull-backup.ps1                забрать свежий снимок
#   .\scripts\pull-backup.ps1 -WhatIf        показать план, на сервер не ходить
#   .\scripts\pull-backup.ps1 -KeepDays 60   держать дольше
#
# Схема: снимок качается во временный .incoming, сверяется по SHA256 пофайлово
# и только потом переносится на место. В хранилище оборванная закачка не видна
# под правильным именем. Забираются только снимки с отметкой OK (её пишет
# db-backup.sh последней).
#
# Коды выхода для планировщика: 0 - снимок забран и свежий, 1 - ошибка,
# 2 - снимок забран, но сервер давно не делает новых (старше STALE_HOURS).
#
# Ключ ssh в скрипте не задаётся: адрес берётся из project.conf, личность из
# ssh-агента. BatchMode=yes: если ключа нет, ssh откажет без вопроса, а не повиснет.
# Файл сохранён как UTF-8 with BOM.
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'project.conf'),
    [string]$Destination = '',
    [int]$KeepDays = 0,
    [int]$KeepAtLeast = 0,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib-backup.ps1')

$conf = Read-Conf $ConfigPath
foreach ($key in 'PROJECT_SLUG', 'SERVER_HOST', 'SERVER_USER', 'SERVER_BACKUP_DIR', 'LOCAL_BACKUP_ROOT') {
    if (-not $conf[$key]) { throw "в project.conf не задан $key" }
}

$slug = $conf['PROJECT_SLUG']
$root = Join-Path $conf['LOCAL_BACKUP_ROOT'] $slug
if (-not $Destination) { $Destination = Join-Path $root 'db' }
$stateDir = Join-Path $root 'state'
$logDir   = Join-Path $stateDir 'logs'

if ($KeepDays -le 0)    { $KeepDays    = if ($conf['KEEP_DAYS'])     { [int]$conf['KEEP_DAYS'] }     else { 30 } }
if ($KeepAtLeast -le 0) { $KeepAtLeast = if ($conf['KEEP_AT_LEAST']) { [int]$conf['KEEP_AT_LEAST'] } else { 3 } }
$staleHours = if ($conf['STALE_HOURS']) { [int]$conf['STALE_HOURS'] } else { 26 }

$SSH_ROOT   = "$($conf['SERVER_USER'])@$($conf['SERVER_HOST'])"
$REMOTE_DIR = "$($conf['SERVER_BACKUP_DIR'])/db/daily"
$MARKER     = 'OK'
$CORE       = 'database.dump'
# -n: ssh не читает stdin консоли и не держит её (в планировщике иначе «выполняется» вечно).
$SSH_ARGS = @('-n', '-o', 'BatchMode=yes')
$SCP_ARGS = @('-o', 'BatchMode=yes')

# ============================================================ план
# -WhatIf не делает ничего: ни на сервер, ни на диск.
if ($WhatIf) {
    Write-Host ''
    Write-Host 'ПЛАН (ничего не делается)' -ForegroundColor Yellow
    Write-Host "  сервер:     $SSH_ROOT"
    Write-Host "  откуда:     $REMOTE_DIR/<свежий снимок>"
    Write-Host "  куда:       $Destination"
    Write-Host "  срок:       $KeepDays дн., но не меньше $KeepAtLeast снимков"
    Write-Host "  свежесть:   тревога, если снимок старше $staleHours ч"
    Write-Host ''
    Write-Host '  Шаги:' -ForegroundColor Cyan
    Write-Host '   1. один вызов ssh: имя свежего каталога и суммы всех файлов в нём'
    Write-Host "   2. отказ, если в снимке нет отметки $MARKER"
    Write-Host '   3. если такой снимок уже есть локально, сверить его и не качать'
    Write-Host '   4. scp -r во временный .incoming'
    Write-Host '   5. сверка сумм пофайлово: нет файла / сумма другая / лишний файл'
    Write-Host '   6. только после сверки перенос из .incoming на место'
    Write-Host '   7. чистка старого по возрасту, с полом'
    Write-Host '   8. метка last-pull.json локально и на сервере (для /status)'
    Write-Host ''
    Write-Host '  Ключ сервера должен лежать в ssh-агенте: ssh-add -l' -ForegroundColor Yellow
    exit 0
}

# ============================================================ журнал
# Пишем на диск сразу: из планировщика консоль никто не видит.
foreach ($d in @($root, $Destination, $stateDir, $logDir)) {
    if (-not (Test-Path -LiteralPath $d)) { [void][System.IO.Directory]::CreateDirectory($d) }
}
$STAMP_NOW = Get-Date -Format 'yyyyMMdd-HHmmss'
$LOGFILE = Join-Path $logDir "pull-backup-$STAMP_NOW.log"
Start-Transcript -Path $LOGFILE -Append | Out-Null
# Старые логи: удаляем только свои по маске имени
Get-ChildItem -LiteralPath $logDir -Filter 'pull-backup-*.log' -File |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-60) } |
    Remove-Item -Force -ErrorAction SilentlyContinue

function Write-Step([string]$text) {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $text" -ForegroundColor Cyan
}

function Write-Verdict {
    # Итог коротким блоком: его читают с телефона или находят в логе задания.
    param([string]$State, [string]$What, [string]$Note = '', [string[]]$Warn = @())
    $color = 'Red'
    if ($State -eq 'OK') { $color = 'Green' }
    if ($State -eq 'STALE') { $color = 'Yellow' }
    Write-Host ''
    Write-Host '================================' -ForegroundColor $color
    switch ($State) {
        'OK'    { Write-Host "  ЗАБРАНО: $What" -ForegroundColor Green }
        'STALE' { Write-Host "  ЗАБРАНО, НО СНИМОК СТАРЫЙ: $What" -ForegroundColor Yellow }
        default { Write-Host "  ОТКАЗ: $What" -ForegroundColor Red }
    }
    Write-Host "  сервер:     $($conf['SERVER_HOST'])" -ForegroundColor $color
    Write-Host "  хранилище:  $Destination" -ForegroundColor $color
    if ($Note) { Write-Host "  $Note" -ForegroundColor Yellow }
    foreach ($line in $Warn) { Write-Host "  ВНИМАНИЕ: $line" -ForegroundColor Yellow }
    Write-Host "  лог:        $LOGFILE" -ForegroundColor $color
    Write-Host '================================' -ForegroundColor $color
}

# ============================================================ работа
$failed = $null
$verdictWhat = ''
$verdictNote = ''
$state = 'OK'
$warn = @()
$stamp = ''
$fileCount = 0
$sizeBytes = 0
$ageHours = 0

try {
    $incoming = Join-Path $Destination '.incoming'
    if (Test-Path -LiteralPath $incoming) { Remove-Item -LiteralPath $incoming -Recurse -Force }
    [void][System.IO.Directory]::CreateDirectory($incoming)

    Write-Step 'спрашиваю сервер: свежий снимок и суммы файлов'
    # Одним обращением: между «найди свежий» и «посчитай суммы» мог бы влезть ночной
    # ротационный запуск, и расхождение мы бы приписали передаче.
    # Команда в одинарных кавычках без вложенных: PowerShell 5.1 теряет вложенные
    # кавычки при передаче в ssh.exe. find вместо глоба, чтобы видеть и скрытые файлы.
    $remote = 'cd ' + $REMOTE_DIR + ' && d=$(ls -1d */ | sort | tail -1) && echo DIR=$d && cd $d && find . -type f -exec sha256sum {} +'
    $res = Invoke-Native { ssh @SSH_ARGS $SSH_ROOT $remote }
    if ($res.Code -ne 0) {
        throw "сервер не отдал список снимков (ssh код $($res.Code)). Проверьте, что ключ лежит в агенте: ssh-add -l"
    }
    $listing = Read-RemoteListing -Lines $res.Output -Marker $MARKER
    $stamp = $listing.Stamp
    $expected = $listing.Files
    $fileCount = $expected.Count
    Write-Host "    снимок $stamp, файлов $fileCount" -ForegroundColor Green

    $ageHours = Get-StampAgeHours $stamp
    if ($ageHours -gt $staleHours) {
        # Сервер перестал делать новые снимки: «успешно забрали старое» было бы ложным успехом.
        $state = 'STALE'
        $warn += "свежему снимку $ageHours ч, порог $staleHours ч: проверьте cron на сервере"
    }

    $target = Join-Path $Destination $stamp
    $haveItAlready = $false
    if (Test-Path -LiteralPath $target) {
        Write-Step "снимок $stamp уже есть локально, сверяю его"
        $already = Test-CopyIntact -Expected $expected -Directory $target
        if ($already.Count -eq 0) {
            Write-Host '    сошлось, качать нечего' -ForegroundColor Green
            $haveItAlready = $true
        } else {
            foreach ($line in $already) { Write-Host "    $line" -ForegroundColor Yellow }
            Write-Host '    прежняя копия не сошлась, качаю заново' -ForegroundColor Yellow
            $warn += "локальная копия $stamp была испорчена и перекачана"
        }
    }

    if (-not $haveItAlready) {
        Write-Step "забираю $stamp"
        # scp получает точкой назначения `.`, а не путь: в аргументах нет ни кириллицы,
        # ни буквы диска с двоеточием, которую scp принял бы за имя хоста.
        Push-Location -LiteralPath $incoming
        try {
            $scp = Invoke-Native { scp @SCP_ARGS -r "${SSH_ROOT}:$REMOTE_DIR/$stamp" . }
        }
        finally { Pop-Location }

        $downloaded = Join-Path $incoming $stamp
        # Код возврата scp отвечает «передача завершилась», а не «содержимое то же».
        if ($scp.Code -ne 0) { throw "scp не отработал (код $($scp.Code)), снимок $stamp не забран" }
        if (-not (Test-Path -LiteralPath $downloaded)) {
            throw "scp отчитался успехом, но каталога $stamp нет: забирать нечего"
        }

        Write-Step 'сверяю суммы пофайлово'
        $problems = Test-CopyIntact -Expected $expected -Directory $downloaded
        if ($problems.Count -gt 0) {
            foreach ($line in $problems) { Write-Host "    $line" -ForegroundColor Red }
            throw "снимок $stamp доехал с потерями: расхождений $($problems.Count). В хранилище он не положен."
        }
        Write-Host "    все $fileCount файлов совпали" -ForegroundColor Green

        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
        Move-Item -LiteralPath $downloaded -Destination $target
        Write-Step "положен: $target"
    }

    $sizeBytes = (Get-ChildItem -LiteralPath $target -Recurse -File | Measure-Object -Property Length -Sum).Sum
    if (-not $sizeBytes) { $sizeBytes = 0 }
    $sizeMb = [math]::Round($sizeBytes / 1MB, 1)

    Write-Step "чистка старше $KeepDays дн. (не меньше $KeepAtLeast снимков)"
    $removed = @(Remove-OldCopies -Store $Destination -Days $KeepDays -AtLeast $KeepAtLeast -Core $CORE)
    if ($removed.Count -gt 0) { Write-Host "    удалено: $($removed -join ', ')" -ForegroundColor Green }
    else { Write-Host '    удалять нечего' -ForegroundColor Green }

    $kept = @(Get-ChildItem -LiteralPath $Destination -Directory | Where-Object { $_.Name -match '^\d{8}-\d{6}$' })
    $verdictWhat = "$stamp, файлов $fileCount, $sizeMb МБ, возраст $ageHours ч"
    $verdictNote = "снимков в хранилище: $($kept.Count)"
    if ($haveItAlready) { $verdictNote = "$verdictNote, этот снимок уже был" }

    # Метка свежести. Локально и на сервере: /status на сервере видит возраст копии на ПК.
    $isStale = ($state -eq 'STALE')
    $json = '{{"finished_at":"{0}","snapshot":"{1}","files":{2},"bytes":{3},"age_hours":{4},"stale":{5}}}' -f `
        (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'), $stamp, $fileCount, $sizeBytes, `
        ([string]$ageHours).Replace(',', '.'), $isStale.ToString().ToLower()
    $markerPath = Join-Path $stateDir 'last-pull.json'
    Write-Utf8NoBom $markerPath $json

    if ($conf['SERVER_STATE_DIR']) {
        Push-Location -LiteralPath $stateDir
        try {
            $up = Invoke-Native { scp @SCP_ARGS 'last-pull.json' "${SSH_ROOT}:$($conf['SERVER_STATE_DIR'])/last-pull.json" }
        }
        finally { Pop-Location }
        if ($up.Code -ne 0) { $warn += 'метку last-pull.json не удалось отправить на сервер' }
    }
}
catch {
    $failed = $_
}
finally {
    # Остаток незавершённой закачки не оставляем: он не копия, а место занимает.
    $leftover = Join-Path $Destination '.incoming'
    if (Test-Path -LiteralPath $leftover) {
        Remove-Item -LiteralPath $leftover -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($failed) {
    Write-Host ''
    Write-Host $failed.Exception.Message -ForegroundColor Red
    Write-Verdict -State 'FAIL' -What 'снимок не забран' -Note 'Прежние снимки в хранилище не тронуты.'
    Stop-Transcript | Out-Null
    exit 1
}

Write-Verdict -State $state -What $verdictWhat -Note $verdictNote -Warn $warn
Stop-Transcript | Out-Null
if ($state -eq 'STALE') { exit 2 }
exit 0
