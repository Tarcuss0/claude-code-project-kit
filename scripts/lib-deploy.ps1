# Функции deploy.ps1. Подключается через dot-source вместе с lib-backup.ps1 (Read-Conf, Invoke-Native):
#   . (Join-Path $PSScriptRoot 'lib-backup.ps1'); . (Join-Path $PSScriptRoot 'lib-deploy.ps1')
# Функции принимают путь репозитория и сервер параметрами, поэтому проверяются без боевого
# сервера: tests/lib-deploy.tests.ps1 (git во временных репозиториях) и tests/deploy.e2e.ps1.
# Файл сохранён как UTF-8 with BOM.

$script:SshArgs = @('-n', '-o', 'BatchMode=yes')
$script:ScpArgs = @('-o', 'BatchMode=yes')
# -n обязателен: без него ssh наследует stdin консоли и после выкатки не возвращает приглашение,
# пока не нажмут Enter. BatchMode=yes: ssh никогда ничего не спрашивает (ни пароль, ни ключ хоста).
# Вопрос, заданный в никуда, это то же зависание. Ключ хоста принимается заранее, руками.

function Get-Artifacts {
    # Артефакты из project.conf: DEPLOY_ARTIFACTS=a,b (порядок = порядок выкатки) и ключи <имя>.KEY.
    param([hashtable]$Conf)

    $list = @("$($Conf['DEPLOY_ARTIFACTS'])" -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($list.Count -eq 0) { throw 'в project.conf не задан DEPLOY_ARTIFACTS (например backend,frontend)' }

    $result = @()
    foreach ($name in $list) {
        if ($name -notmatch '^[A-Za-z][A-Za-z0-9_-]*$') { throw "недопустимое имя артефакта '$name'" }
        $get = { param($k) $v = $Conf["$name.$k"]; if ($null -eq $v) { '' } else { $v } }
        $a = [pscustomobject]@{
            Name          = $name
            SshUser       = (& $get 'SSH_USER')
            RemoteDir     = (& $get 'REMOTE_DIR')
            ReleaseScript = (& $get 'RELEASE_SCRIPT')
            Receiver      = (& $get 'RECEIVER')
            HealthUrl     = (& $get 'HEALTH_URL')
            BuildCmd      = (& $get 'BUILD_CMD')
            VersionDir    = (& $get 'VERSION_DIR')
        }
        foreach ($required in 'SshUser', 'RemoteDir', 'BuildCmd') {
            if (-not $a.$required) { throw "для артефакта $name не задан $name.$(@{SshUser='SSH_USER';RemoteDir='REMOTE_DIR';BuildCmd='BUILD_CMD'}[$required])" }
        }
        if (-not $a.Receiver) {
            if (-not $a.ReleaseScript) { throw "для артефакта $name нужен $name.RELEASE_SCRIPT или $name.RECEIVER" }
            $a.Receiver = "$($a.ReleaseScript) --root $($a.RemoteDir)"
        }
        $result += $a
    }
    return $result
}

function Test-Origin {
    # Что мы знаем о ветке относительно origin. Поле state:
    #   ok, ahead (не запушено), behind (не забрано), diverged (и то и другое),
    #   no-upstream (у ветки нет origin), offline (origin не ответил).
    # ahead и offline различаются обязательно: в первом случае жмут git push, во втором лезут в сеть.
    param([string]$Repo)

    $upstream = (Invoke-Native { git -C $Repo rev-parse --abbrev-ref --symbolic-full-name '@{u}' })
    if ($upstream.Code -ne 0 -or -not $upstream.Output) {
        return [pscustomobject]@{ state = 'no-upstream'; upstream = $null; ahead = 0; behind = 0 }
    }
    $name = "$($upstream.Output[0])".Trim()

    $fetch = Invoke-Native { git -C $Repo fetch --quiet }
    if ($fetch.Code -ne 0) {
        # Последнее, что мы знаем об origin, это прошлый удачный fetch. Судить по нему нельзя.
        return [pscustomobject]@{ state = 'offline'; upstream = $name; ahead = 0; behind = 0 }
    }
    $counts = Invoke-Native { git -C $Repo rev-list --left-right --count "$name...HEAD" }
    if ($counts.Code -ne 0 -or -not $counts.Output) {
        return [pscustomobject]@{ state = 'offline'; upstream = $name; ahead = 0; behind = 0 }
    }
    $parts = @("$($counts.Output[0])" -split '\s+' | Where-Object { $_ })
    $behind = [int]$parts[0]
    $ahead = [int]$parts[1]

    $state = 'ok'
    if ($ahead -gt 0 -and $behind -gt 0) { $state = 'diverged' }
    elseif ($ahead -gt 0) { $state = 'ahead' }
    elseif ($behind -gt 0) { $state = 'behind' }
    return [pscustomobject]@{ state = $state; upstream = $name; ahead = $ahead; behind = $behind }
}

function Get-DirtyFiles {
    param([string]$Repo)
    $r = Invoke-Native { git -C $Repo -c core.quotepath=false status --porcelain }
    return @($r.Output | Where-Object { $_ -and $_.Trim() })
}

function Write-TreeProblems {
    # Разбор отказа: что не так и что сделать. Печатает и возвращает $true, если выкатка невозможна.
    param($Dirty, $Origin, [string]$Branch)

    if ($Dirty.Count -gt 0) {
        Write-Host "В дереве есть незакоммиченные изменения, файлов: $($Dirty.Count)." -ForegroundColor Yellow
        foreach ($p in $Dirty) { Write-Host "    $p" }
        Write-Host ''
        Write-Host 'Артефакт собирается из рабочего дерева, а не из репозитория: уедет ровно то, что видно выше,'
        Write-Host 'включая чужую незаконченную работу и миграции. Откатиться будет некуда: этого состояния'
        Write-Host 'нет ни в одном коммите.'
        Write-Host ''
        Write-Host 'Что сделать:' -ForegroundColor Cyan
        Write-Host '  git status                              посмотреть, своё это или соседа'
        Write-Host '  git add <файлы>; git commit; git push   если своё и готово'
        Write-Host '  git stash                               если своё и не готово'
        Write-Host '  .\scripts\deploy.ps1 -Force             если понимаете, что делаете'
        Write-Host ''
    }
    switch ($Origin.state) {
        'ahead' {
            Write-Host "Ветка $Branch впереди $($Origin.upstream) на $($Origin.ahead) коммит(ов): они не запушены." -ForegroundColor Yellow
            Write-Host 'Выкаченный код должен существовать в репозитории, иначе его не увидит ни вторая сессия, ни вы с другой машины.'
            Write-Host 'Что сделать:  git push'
            Write-Host ''
        }
        'behind' {
            Write-Host "Ветка $Branch отстала от $($Origin.upstream) на $($Origin.behind) коммит(ов)." -ForegroundColor Yellow
            Write-Host 'В origin есть работа, которой здесь нет: выкатка её затрёт, на прод уедет состояние старее репозитория.'
            Write-Host 'Что сделать:  git pull --rebase'
            Write-Host ''
        }
        'diverged' {
            Write-Host "Ветка $Branch разошлась с $($Origin.upstream): своих коммитов $($Origin.ahead), не забрано $($Origin.behind)." -ForegroundColor Yellow
            Write-Host 'Что сделать:  git pull --rebase, затем git push'
            Write-Host ''
        }
        'no-upstream' {
            Write-Host "У ветки $Branch нет ветки в origin: сверять не с чем." -ForegroundColor Yellow
            Write-Host "Что сделать:  git push -u origin $Branch"
            Write-Host ''
        }
        'offline' {
            Write-Host "origin не ответил ($($Origin.upstream)): сверить с репозиторием не удалось." -ForegroundColor Yellow
            Write-Host 'Это НЕ значит, что вы что-то не запушили: возможно, нет сети, спит VPN или протух токен.'
            Write-Host 'Что сделать:  git fetch (проверить связь и повторить), либо -Force, если уверены, что запушено.'
            Write-Host ''
        }
    }
}

function Assert-Deployable {
    # Страж перед сборкой: уезжает то, что лежит в репозитории, и ничего сверх того.
    # Отказ, а не предупреждение: жёлтую строку в момент выкатки пролистывают.
    # Возвращает объект: Ok, Forced, Dirty, Origin. Кидает исключение, если выкатка невозможна.
    param([string]$Repo, [switch]$Force)

    $dirty = Get-DirtyFiles -Repo $Repo
    $branch = ((Invoke-Native { git -C $Repo rev-parse --abbrev-ref HEAD }).Output | Select-Object -First 1)
    $origin = Test-Origin -Repo $Repo

    $clean = ($dirty.Count -eq 0 -and $origin.state -eq 'ok')
    if ($clean) {
        Write-Host "  дерево чистое, $branch совпадает с $($origin.upstream)" -ForegroundColor Green
        return [pscustomobject]@{ Ok = $true; Forced = $false; Dirty = $dirty; Origin = $origin }
    }

    if ($Force) {
        Write-Host ''
        Write-Host '#############################################################' -ForegroundColor Red
        Write-Host '#  ВЫКАТКА С -Force: НА ПРОД УЕЗЖАЕТ НЕ ТО, ЧТО В РЕПОЗИТОРИИ  #' -ForegroundColor Red
        Write-Host '#############################################################' -ForegroundColor Red
        if ($dirty.Count -gt 0) {
            Write-Host "  Незакоммиченных файлов: $($dirty.Count). Все они уедут:" -ForegroundColor Red
            foreach ($p in $dirty) { Write-Host "    $p" }
        }
        if ($origin.state -ne 'ok') { Write-Host "  Состояние относительно origin: $($origin.state)." -ForegroundColor Red }
        Write-Host '  Откатиться к этому состоянию по git будет нельзя: его нет ни в одном коммите.' -ForegroundColor Yellow
        Write-Host ''
        return [pscustomobject]@{ Ok = $true; Forced = $true; Dirty = $dirty; Origin = $origin }
    }

    Write-Host ''
    Write-Host 'ВЫКАТКА ОСТАНОВЛЕНА' -ForegroundColor Red
    Write-Host ''
    Write-TreeProblems -Dirty $dirty -Origin $origin -Branch $branch
    throw 'Дерево не готово к выкатке. Разбор выше; осознанный случай: ключ -Force.'
}

function Write-Marker {
    # Маркер выкаченного состояния: что сейчас на проде. По записи на каждый артефакт.
    # Entries: hashtable имя -> запись (commit, commit_short, release, branch, dirty, deployed_at).
    # Пишется по факту уехавшего (то, что сервер принял и подтвердил), а не по тому, что собирались выкатить.
    # Коммит обязателен (иначе маркер виден только этой машине), пуш попытка: неудача выкатку не роняет.
    param([string]$Root, [hashtable]$Entries, [string]$Stamp, [string]$Label = 'Выкатка')

    if ($Entries.Count -eq 0) { return $null }
    $dir = Join-Path $Root 'deploy'
    [void][System.IO.Directory]::CreateDirectory($dir)
    $file = Join-Path $dir 'deployed.json'

    $state = @{}
    if (Test-Path -LiteralPath $file) {
        # -AsHashtable в Windows PowerShell 5.1 нет (появился в 7): собираем руками.
        try {
            $parsed = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($prop in $parsed.PSObject.Properties) { $state[$prop.Name] = $prop.Value }
        }
        catch { $state = @{} }
    }

    foreach ($name in $Entries.Keys) { $state[$name] = $Entries[$name] }

    $now = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
    $first = $Entries[@($Entries.Keys)[0]]
    $history = @()
    if ($state.ContainsKey('history') -and $state['history']) { $history = @($state['history']) }
    $history = @(@{ at = $now; components = @($Entries.Keys); commit_short = $first.commit_short; release = $Stamp }) + $history
    if ($history.Count -gt 20) { $history = $history[0..19] }
    $state['history'] = $history

    # Без BOM: файл читает deployed.py, а Set-Content -Encoding UTF8 в 5.1 ставит метку.
    Write-Utf8NoBom -Path $file -Text ($state | ConvertTo-Json -Depth 6)

    $names = (@($Entries.Keys) | Sort-Object) -join ', '
    $add = Invoke-Native { git -C $Root add 'deploy/deployed.json' }
    # Только маркер: в дереве могут жить несколько сессий, общий коммит увёз бы чужую работу.
    $commit = Invoke-Native { git -C $Root commit -o 'deploy/deployed.json' -m "${Label} ${Stamp}: $names на $($first.commit_short)" }
    $committed = ($commit.Code -eq 0)
    if (-not $committed) { Write-Host '    маркер: коммитить нечего (состояние не изменилось)' -ForegroundColor DarkGray }
    $push = Invoke-Native { git -C $Root push }
    $pushed = ($push.Code -eq 0)
    if (-not $pushed) {
        Write-Host '    маркер записан, но не запушен: origin не ответил. Сессии на этой машине его увидят, на другой нет: git push' -ForegroundColor Yellow
    }
    return [pscustomobject]@{ Committed = $committed; Pushed = $pushed; File = $file }
}

function Write-Verdict {
    # Итог коротким блоком: его читают с телефона. Простыни выше остаются для разбора.
    param([string]$State, [string]$What, $Version, [string]$Stamp, [string]$LogFile, [string]$Note = '', [string[]]$Warn = @())

    $color = if ($State -eq 'OK') { 'Green' } else { 'Red' }
    Write-Host ''
    Write-Host '================================' -ForegroundColor $color
    if ($State -eq 'OK') { Write-Host "  ВЫКАЧЕНО: $What" -ForegroundColor Green }
    else { Write-Host "  ОТКАЗ: $What" -ForegroundColor Red }
    if ($Version) { Write-Host "  версия:  $($Version.version)" -ForegroundColor $color }
    Write-Host "  релиз:   $Stamp" -ForegroundColor $color
    if ($Note) { Write-Host "  $Note" -ForegroundColor Yellow }
    foreach ($line in $Warn) { Write-Host "  ВНИМАНИЕ: $line" -ForegroundColor Yellow }
    Write-Host "  лог:     $LogFile" -ForegroundColor $color
    Write-Host '================================' -ForegroundColor $color
}

function Get-RemoteVersion {
    # Версия, которую артефакт отдаёт сам: GET HealthUrl на сервере, поле version.commit.
    # Status: ok, no-url, unreachable, not-json, no-version.
    param($Artifact, [string]$Server)

    $sshArgs = $script:SshArgs
    if (-not $Artifact.HealthUrl) { return [pscustomobject]@{ Status = 'no-url'; Version = $null } }
    $target = "$($Artifact.SshUser)@$Server"
    $url = $Artifact.HealthUrl
    $r = Invoke-Native { ssh @sshArgs $target "curl -fsS -m 5 $url" }
    if ($r.Code -ne 0) { return [pscustomobject]@{ Status = 'unreachable'; Version = $null } }

    # Предупреждения ssh могут стоять рядом с JSON: берём от первой { до последней }.
    $text = ($r.Output -join "`n")
    $i = $text.IndexOf('{')
    $j = $text.LastIndexOf('}')
    if ($i -lt 0 -or $j -le $i) { return [pscustomobject]@{ Status = 'not-json'; Version = $null } }
    try { $body = $text.Substring($i, $j - $i + 1) | ConvertFrom-Json }
    catch { return [pscustomobject]@{ Status = 'not-json'; Version = $null } }

    if (-not $body.version -or -not $body.version.commit) { return [pscustomobject]@{ Status = 'no-version'; Version = $null } }
    return [pscustomobject]@{ Status = 'ok'; Version = $body.version }
}

function Confirm-Deployed {
    # Сверка после выкатки: тот ли РЕЛИЗ поднялся. Сравнивается хеш коммита, а не имя релиза.
    # Что она НЕ доказывает: хеш сверяется с HEAD этой машины, то есть коммит сам с собой. О содержимом
    # артефакта она не говорит ничего: на грязном дереве коммит совпадёт, а уехало другое.
    # Расхождение выкатку не роняет: она уже прошла, полезнее внятное предупреждение, чем красная простыня.
    # Возвращает match, mismatch или unverified.
    param($Artifact, [string]$Server, $Version)

    $seen = Get-RemoteVersion -Artifact $Artifact -Server $Server
    $what = $Artifact.Name
    switch ($seen.Status) {
        'no-url' { Write-Host "    ${what}: HEALTH_URL не задан, версию проверить нечем" -ForegroundColor Yellow; return 'unverified' }
        'unreachable' { Write-Host "    ${what}: версию проверить не удалось, $($Artifact.HealthUrl) не ответил" -ForegroundColor Yellow; return 'unverified' }
        'not-json' { Write-Host "    ${what}: ответ здоровья не разобран как JSON" -ForegroundColor Yellow; return 'unverified' }
        'no-version' { Write-Host "    ${what}: здоровье версию не отдаёт (нужно поле version.commit)" -ForegroundColor Yellow; return 'unverified' }
    }
    if ($seen.Version.commit -eq $Version.commit) {
        Write-Host "    ${what}: на сервере $($seen.Version.version), тот коммит, из которого собирали" -ForegroundColor Green
        if ($seen.Version.dirty) {
            Write-Host '      но артефакт собран из грязного дерева: совпадение коммитов не говорит, что на сервере содержимое репозитория.' -ForegroundColor Yellow
        }
        return 'match'
    }
    Write-Host "    ${what}: НА СЕРВЕРЕ ДРУГОЙ КОММИТ" -ForegroundColor Red
    Write-Host "      сервер: $($seen.Version.commit)"
    Write-Host "      дерево: $($Version.commit)"
    Write-Host '      Похоже, симлинк остался на прежнем релизе: проверьте вывод выше.' -ForegroundColor Yellow
    return 'mismatch'
}

function Send-ServerScripts {
    # Обновляет серверный release.sh. Он ставится один раз руками, а выкатка его не обновляла бы: она вызывает
    # тот файл, что уже лежит на сервере, и правка в репозитории до прода не доезжала бы вовсе.
    #
    # Ставим ПОСЛЕ успешной заливки, и это главное решение. Выкатка всегда идёт приёмом, проверенным работой;
    # новый следом. Положенный первым сломанный приём отбирает и заливку, и откат: заменяемый файл и есть
    # тот, которым мы работаем. Цена: правка приёма вступает в силу со СЛЕДУЮЩЕЙ выкатки.
    #
    # Неудача доставки не отказ выкатки: прод уже обновлён и работает. Возвращается список бед.
    # Промежуточный файл для root лежит в /root, не в /tmp: /tmp пишут все, и подмена симлинком или файлом
    # между scp и install дала бы выдачу root. Для остальных пользователей это incoming/ их артефакта.
    param([string]$Root, $Artifacts, [string]$Server)

    $problems = @()
    $sshArgs = $script:SshArgs
    $scpArgs = $script:ScpArgs
    $local = Join-Path (Join-Path $Root 'server') 'release.sh'
    foreach ($a in $Artifacts) {
        if (-not $a.ReleaseScript) { continue }
        if (-not (Test-Path -LiteralPath $local)) { $problems += "$($a.Name): server/release.sh нет в репозитории"; continue }

        # Скрипт с CRLF на сервере не запустится вовсе (bash не понимает #!/usr/bin/env bash\r).
        $bytes = [System.IO.File]::ReadAllBytes($local)
        if ($bytes -contains 13) { $problems += "$($a.Name): в release.sh концы строк CRLF, на сервере не запустится, не отправлен"; continue }

        $target = "$($a.SshUser)@$Server"
        $tmp = if ($a.SshUser -eq 'root') { '/root/release.sh.new' } else { "$($a.RemoteDir)/incoming/release.sh.new" }
        $dst = $a.ReleaseScript

        $up = Invoke-Native { scp @scpArgs $local "${target}:$tmp" }
        if ($up.Code -ne 0) { $problems += "$($a.Name): release.sh не залился (scp код $($up.Code))"; continue }
        $inst = Invoke-Native { ssh @sshArgs $target "install -m 755 $tmp $dst" }
        if ($inst.Code -ne 0) { $problems += "$($a.Name): release.sh не установился (install код $($inst.Code))"; continue }

        # Сверка хешей, а не факта «команда прошла»: grep отвечает «строка есть», а не «файл тот».
        $mine = (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash.ToLower()
        $sum = Invoke-Native { ssh @sshArgs $target "sha256sum $dst" }
        $there = if ($sum.Code -eq 0 -and $sum.Output) { ("$($sum.Output[0])".Trim() -split '\s+')[0] } else { '' }
        if (-not $there) { $problems += "$($a.Name): release.sh установлен, но сверить не удалось"; continue }
        if ($there -ne $mine) { $problems += "$($a.Name): на сервере ДРУГОЙ release.sh (хеши разошлись)"; continue }
        Write-Host "    $($a.Name): release.sh совпадает с репозиторием" -ForegroundColor Green
    }
    return $problems
}
