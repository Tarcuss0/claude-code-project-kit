# Выкатка. Запускаете вы сами, руками, после git push. Сессии Claude Code её не запускают.
#
#   .\scripts\deploy.ps1                       все артефакты из DEPLOY_ARTIFACTS, по порядку
#   .\scripts\deploy.ps1 -Only backend         только названные (порядок остаётся из конфигурации)
#   .\scripts\deploy.ps1 -WhatIf               план и настоящие проверки дерева, на сервер не ходит
#   .\scripts\deploy.ps1 -Force                выкатить грязное или разошедшееся с origin дерево
#   .\scripts\deploy.ps1 -MarkOnly             записать маркер по факту, ничего не выкатывая
#   .\scripts\deploy.ps1 -Rollback backend     вернуть артефакт на прежний релиз, маркер по факту
#   .\scripts\deploy.ps1 -WithTests            плюс полный набор тестов (TEST_CMD), по умолчанию выключен
#
# Настройки берутся из scripts\project.conf (пример: project.conf.example), порядок и причины: docs\DEPLOY.md.
# Файл сохранён как UTF-8 with BOM.
param(
    [string[]]$Only,
    [switch]$WhatIf,
    [switch]$Force,
    [switch]$MarkOnly,
    [string]$Rollback,
    [switch]$WithTests,
    [string]$Server,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'project.conf')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib-backup.ps1')
. (Join-Path $PSScriptRoot 'lib-deploy.ps1')
. (Join-Path $PSScriptRoot 'version-stamp.ps1')

$conf = Read-Conf $ConfigPath
if (-not $Server) { $Server = $conf['SERVER_HOST'] }
if (-not $Server) { throw 'не задан SERVER_HOST в project.conf (или ключ -Server)' }
$python = if ($conf['PYTHON_CMD']) { $conf['PYTHON_CMD'] } else { 'python' }
$sshArgs = $script:SshArgs
$scpArgs = $script:ScpArgs

$ROOT = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$STAMP = Get-Date -Format 'yyyyMMdd-HHmmss'
$all = Get-Artifacts $conf

if ($Only) {
    $unknown = @($Only | Where-Object { $all.Name -notcontains $_ })
    if ($unknown.Count -gt 0) { throw "нет такого артефакта в DEPLOY_ARTIFACTS: $($unknown -join ', ')" }
    $selected = @($all | Where-Object { $Only -contains $_.Name })
} else {
    $selected = $all
}

# Журнал: первое, что делает скрипт. Выкатку запускают удалённо, и внутренности уходят в никуда,
# если лог не лежит на диске. Свой файл на каждый запуск; путь печатается в начале и в конце,
# потому что упавший на середине скрипт до конца не доходит.
$LOGDIR = Join-Path $ROOT '.deploy-logs'
[void][System.IO.Directory]::CreateDirectory($LOGDIR)
$LOGFILE = Join-Path $LOGDIR "deploy-$STAMP.log"
Start-Transcript -Path $LOGFILE -Append | Out-Null

# Что уже доехало до сервера: пополняется сразу после успешной заливки каждого артефакта, а не в конце.
# Между «артефакт уехал» и «скрипт дошёл до конца» бывают обрывы, и итог должен судить по тому, что
# произошло на сервере, а не по тому, дошёл ли ДО конца сам скрипт.
$script:Done = [ordered]@{}

function Stop-Deploy([int]$Code) {
    Stop-Transcript | Out-Null
    exit $Code
}

function Invoke-Step([string]$What, [scriptblock]$Block) {
    # Прямой вызов, без перехвата stderr: вывод ssh и scp идёт в консоль и в журнал сразу.
    & $Block | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "${What}: код $LASTEXITCODE" }
}

function New-Entry($Version) {
    return @{
        commit       = $Version.commit
        commit_short = $Version.commit_short
        release      = $STAMP
        branch       = $Version.branch
        dirty        = [bool]$Version.dirty
        deployed_at  = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
    }
}

if ($Only -and $Rollback) { throw 'ключи -Only и -Rollback вместе не нужны' }
if ($Rollback -and ($all.Name -notcontains $Rollback)) { throw "нет такого артефакта: $Rollback" }

$VERSION = Get-VersionStamp -Root $ROOT -Release $STAMP
Write-Host "Релиз $STAMP · $(Format-VersionLine $VERSION)" -ForegroundColor Cyan
Write-Host "Лог: $LOGFILE" -ForegroundColor Cyan

# ---------------------------------------------------------------- откат
if ($Rollback) {
    $a = $all | Where-Object { $_.Name -eq $Rollback }
    $target = "$($a.SshUser)@$Server"
    Write-Host ''
    Write-Host "ОТКАТ $($a.Name) на прежний релиз" -ForegroundColor Yellow
    try {
        Invoke-Step 'откат' { ssh @sshArgs $target "$($a.Receiver) rollback" }
    }
    catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
        Write-Verdict -State 'FAIL' -What "откат $($a.Name)" -Version $VERSION -Stamp $STAMP -LogFile $LOGFILE -Note 'Что с продом, сказано в выводе release выше.'
        Stop-Deploy 1
    }
    # Маркер по факту: спрашиваем у сервера, что там теперь, а не верим дереву.
    $seen = Get-RemoteVersion -Artifact $a -Server $Server
    if ($seen.Status -eq 'ok') {
        $v = $seen.Version
        $entry = @{
            commit = $v.commit; commit_short = $v.commit_short; release = $v.release
            branch = $v.branch; dirty = [bool]$v.dirty
            deployed_at = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
        }
        [void](Write-Marker -Root $ROOT -Entries @{ $a.Name = $entry } -Stamp $STAMP -Label 'Откат')
        Write-Verdict -State 'OK' -What "откат $($a.Name) на $($v.commit_short)" -Version $VERSION -Stamp $STAMP -LogFile $LOGFILE `
            -Note 'Схема базы осталась новой: откат возвращает только код.'
    } else {
        Write-Verdict -State 'OK' -What "откат $($a.Name)" -Version $VERSION -Stamp $STAMP -LogFile $LOGFILE `
            -Warn @("версию после отката узнать не удалось ($($seen.Status)): маркер не обновлён, проверьте руками и запустите -MarkOnly")
    }
    Stop-Deploy 0
}

# ---------------------------------------------------------------- маркер по факту
if ($MarkOnly) {
    Write-Host ''
    Write-Host 'ЗАПИСЬ МАРКЕРА (ничего не выкатывается)' -ForegroundColor Yellow
    # Спрашиваем сервер: что там на самом деле. Маркер по вере в дерево это выдуманный файл.
    $entries = @{}
    foreach ($a in $selected) {
        $seen = Get-RemoteVersion -Artifact $a -Server $Server
        if ($seen.Status -ne 'ok') { Write-Host "  $($a.Name): версию узнать не удалось ($($seen.Status)), пропускаем" -ForegroundColor Yellow; continue }
        if ($seen.Version.commit -ne $VERSION.commit) {
            Write-Host "  $($a.Name): на сервере $($seen.Version.commit_short), в дереве $($VERSION.commit_short): не пишем" -ForegroundColor Red
            continue
        }
        Write-Host "  $($a.Name): $($seen.Version.version) совпадает с деревом" -ForegroundColor Green
        $entries[$a.Name] = New-Entry $VERSION
    }
    if ($entries.Count -eq 0) {
        Write-Host 'Маркер не записан: ни один артефакт не подтвердил версию дерева.' -ForegroundColor Red
        Stop-Deploy 1
    }
    [void](Write-Marker -Root $ROOT -Entries $entries -Stamp $STAMP)
    Write-Host "Маркер записан по факту: $(@($entries.Keys) -join ', ')" -ForegroundColor Green
    Stop-Deploy 0
}

# ---------------------------------------------------------------- проверки перед сборкой
function Invoke-PreChecks {
    # Возвращает список претензий (пустой: можно катить). Печатает сама.
    param([switch]$Force)
    $problems = @()

    Write-Host 'Проверка перед сборкой' -ForegroundColor Cyan
    try { [void](Assert-Deployable -Repo $ROOT -Force:$Force) }
    catch { $problems += $_.Exception.Message }

    # Сторожа дерева здесь, а не в git-хуке: хук локален, снимается --no-verify и у трёх сессий
    # будет в трёх состояниях. Через выкатку проходит всё, обойти её нельзя.
    $checks = Join-Path $PSScriptRoot 'checks.py'
    if (Test-Path -LiteralPath $checks) {
        Push-Location $ROOT
        try { & $python $checks | Out-Host } finally { Pop-Location }
        if ($LASTEXITCODE -ne 0) {
            if ($Force) { Write-Host 'Сторожа дерева не прошли, но задан -Force: выкатываем как есть.' -ForegroundColor Yellow }
            else { $problems += 'сторожа дерева не прошли (разбор выше, python scripts\checks.py)' }
        } else { Write-Host '  сторожа дерева прошли' -ForegroundColor Green }
    }

    # Своя проверка проекта (например сверка схемы с базой). Пропуск здесь не зелёный.
    if ($conf['PRE_DEPLOY_CMD']) {
        Write-Host "  PRE_DEPLOY_CMD: $($conf['PRE_DEPLOY_CMD'])"
        Push-Location $ROOT
        try { & (Get-Process -Id $PID).Path -NoProfile -Command $conf['PRE_DEPLOY_CMD'] | Out-Host } finally { Pop-Location }
        if ($LASTEXITCODE -ne 0) {
            if ($Force) { Write-Host 'PRE_DEPLOY_CMD не прошла, но задан -Force: выкатываем как есть.' -ForegroundColor Yellow }
            else { $problems += 'PRE_DEPLOY_CMD не прошла' }
        } else { Write-Host '  PRE_DEPLOY_CMD прошла' -ForegroundColor Green }
    }

    if ($WithTests) {
        if (-not $conf['TEST_CMD']) { $problems += 'TEST_CMD не задан в project.conf' }
        else {
            Push-Location $ROOT
            try { & (Get-Process -Id $PID).Path -NoProfile -Command $conf['TEST_CMD'] | Out-Host } finally { Pop-Location }
            if ($LASTEXITCODE -ne 0) { $problems += 'полный набор тестов упал' }
        }
    } else {
        Write-Host '  полный набор тестов пропущен: так задумано, -WithTests включает его' -ForegroundColor DarkGray
    }
    return $problems
}

if ($WhatIf) {
    Write-Host ''
    Write-Host 'ПЛАН (ничего не делается)' -ForegroundColor Yellow
    Write-Host "  сервер:   $Server"
    Write-Host "  версия:   $($VERSION.version)  ($($VERSION.branch))$(if ($VERSION.dirty) { "  ГРЯЗНОЕ ДЕРЕВО: $($VERSION.dirty_files) файлов" })"
    Write-Host '  порядок:  схема впереди кода, зависимое после того, от чего зависит'
    $n = 0
    foreach ($a in $selected) {
        $n++
        Write-Host "   $n. $($a.Name): сборка ($($a.BuildCmd)), заливка под $($a.SshUser) в $($a.RemoteDir)/incoming, приём: $($a.Receiver) receive"
        if ($a.HealthUrl) { Write-Host "      здоровье и версия: $($a.HealthUrl)" }
    }
    Write-Host '  Проверки:' -ForegroundColor Cyan
    # Мягко: план не выкатка, падать ему не на чем. Но проверки настоящие: иначе план обещал бы
    # выкатку, которую сторожа остановят.
    $blockers = @(Invoke-PreChecks -Force:$Force)
    Write-Host ''
    if ($blockers.Count -gt 0) {
        Write-Host '  ВЫКАТКА НЕ ПРОЙДЁТ, пока не поправлено:' -ForegroundColor Red
        foreach ($line in $blockers) { Write-Host "    · $($line -split "`n" | Select-Object -First 1)" -ForegroundColor Red }
    }
    Write-Host '  Ничего из этого не выполнено: это план.' -ForegroundColor Yellow
    Write-Host "  Лог: $LOGFILE"
    Stop-Deploy 0
}

# ---------------------------------------------------------------- выкатка
$failed = $null
$problems = @(Invoke-PreChecks -Force:$Force)
if ($problems.Count -gt 0) {
    Write-Host ''
    foreach ($line in $problems) { Write-Host $line -ForegroundColor Red }
    Write-Verdict -State 'FAIL' -What 'проверки перед выкаткой' -Version $VERSION -Stamp $STAMP -LogFile $LOGFILE -Note 'Прод не тронут: до сервера дело не дошло.'
    Stop-Deploy 1
}

function Deploy-Artifact($a) {
    $stage = Join-Path $ROOT ".deploy-stage-$($a.Name)"
    $arcName = "$($a.Name)-$STAMP.tgz"
    $archive = Join-Path $ROOT $arcName
    $target = "$($a.SshUser)@$Server"
    $incoming = "$($a.RemoteDir)/incoming"

    try {
        Write-Host "[$($a.Name) 1/4] сборка" -ForegroundColor Cyan
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
        [void][System.IO.Directory]::CreateDirectory($stage)
        $env:STAGE_DIR = $stage
        $env:RELEASE_STAMP = $STAMP
        $env:DEPLOY_ARTIFACT = $a.Name
        Push-Location $ROOT
        try {
            # Сборка идёт дочерним процессом: код выхода однозначен, а её stderr не превращается в ошибки.
            & (Get-Process -Id $PID).Path -NoProfile -Command $a.BuildCmd | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "сборка $($a.Name) вернула код $LASTEXITCODE" }
        }
        finally { Pop-Location }
        if (-not (Get-ChildItem -LiteralPath $stage -Force | Select-Object -First 1)) {
            throw "сборка $($a.Name) ничего не положила в STAGE_DIR ($stage)"
        }

        # Штамп версии кладётся в артефакт: по нему здоровье сервиса отдаёт version, и стенд сверяется с git log.
        $VERSION.component = $a.Name
        $stampDir = if ($a.VersionDir) { Join-Path $stage $a.VersionDir } else { $stage }
        [void](Write-VersionStamp -Stamp $VERSION -Directory $stampDir)

        Write-Host "[$($a.Name) 2/4] упаковка" -ForegroundColor Cyan
        # Путь архива относительный: tar.exe (bsdtar) не знает --force-local, а GNU tar из Git Bash без него
        # принимает «E:» за имя удалённой машины.
        Push-Location $stage
        try { & tar -czf "../$arcName" . | Out-Host; if ($LASTEXITCODE -ne 0) { throw "tar: код $LASTEXITCODE" } }
        finally { Pop-Location }

        Write-Host "[$($a.Name) 3/4] заливка" -ForegroundColor Cyan
        Write-Host "    $([math]::Round((Get-Item -LiteralPath $archive).Length / 1MB, 1)) MB"
        Invoke-Step 'mkdir incoming' { ssh @sshArgs $target "mkdir -p $incoming" }
        Invoke-Step 'scp' { scp @scpArgs $archive "${target}:$incoming/$arcName" }

        Write-Host "[$($a.Name) 4/4] приём на сервере" -ForegroundColor Cyan
        # Внутри приёма: распаковка, подготовка (миграции), симлинк, перезапуск, здоровье, автооткат.
        Invoke-Step 'приём' { ssh @sshArgs $target "$($a.Receiver) receive $arcName" }

        # Отмечаем ЗДЕСЬ: сервер отработал и вернул ноль. Всё, что дальше, это сверка и уборка,
        # и их отказ уже не отменяет того, что артефакт уехал.
        $script:Done[$a.Name] = $true
        Write-Host "$($a.Name) выкачен: $STAMP · $(Format-VersionLine $VERSION)" -ForegroundColor Green
        [void](Confirm-Deployed -Artifact $a -Server $Server -Version $VERSION)
    }
    finally {
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
        if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
    }
}

try {
    foreach ($a in $selected) { Deploy-Artifact $a }
}
catch { $failed = $_ }

function Get-Entries {
    $e = @{}
    foreach ($name in $script:Done.Keys) { $e[$name] = New-Entry $VERSION }
    return $e
}

if ($failed) {
    Write-Host ''
    Write-Host $failed.Exception.Message -ForegroundColor Red
    if ($script:Done.Count -eq 0) {
        Write-Verdict -State 'FAIL' -What 'выкатка' -Version $VERSION -Stamp $STAMP -LogFile $LOGFILE `
            -Note 'Новый релиз не принят: что с продом, сказано в выводе приёма выше (откат делает сам приём).'
    } else {
        # Уехавшее записываем маркером несмотря на отказ: маркер отвечает на «что сейчас на проде».
        [void](Write-Marker -Root $ROOT -Entries (Get-Entries) -Stamp $STAMP)
        Write-Verdict -State 'FAIL' -What 'выкатка не доведена до конца' -Version $VERSION -Stamp $STAMP -LogFile $LOGFILE `
            -Note "УЖЕ на сервере: $(@($script:Done.Keys) -join ', '). Маркер записан."
    }
    Stop-Deploy 1
}

# Серверные скрипты ставятся после заливки и только при успехе: порядок разобран в Send-ServerScripts.
$scriptProblems = @(Send-ServerScripts -Root $ROOT -Artifacts ($selected | Where-Object { $script:Done.Contains($_.Name) }) -Server $Server)
foreach ($line in $scriptProblems) { Write-Host "    $line" -ForegroundColor Yellow }

# По факту уехавшего, а не по флагам.
[void](Write-Marker -Root $ROOT -Entries (Get-Entries) -Stamp $STAMP)

$dirtyNote = ''
if ($VERSION.dirty) { $dirtyNote = "ГРЯЗНОЕ ДЕРЕВО: $($VERSION.dirty_files) файлов вне коммита, по git не вернуться." }
$warn = @()
if ($scriptProblems.Count -gt 0) { $warn += "release.sh на сервере не обновлён ($($scriptProblems.Count)): там прежний приём" }
Write-Verdict -State 'OK' -What (@($script:Done.Keys) -join ', ') -Version $VERSION -Stamp $STAMP -LogFile $LOGFILE -Note $dirtyNote -Warn $warn

Write-Host ''
Write-Host 'Что сейчас на проде:' -ForegroundColor Cyan
Write-Host '  python scripts\deployed.py'
foreach ($a in $selected) {
    if ($a.HealthUrl) { Write-Host "  ssh $($a.SshUser)@$Server curl -s $($a.HealthUrl)" }
}
Stop-Deploy 0
