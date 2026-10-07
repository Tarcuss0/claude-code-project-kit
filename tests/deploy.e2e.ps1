# Сквозной прогон deploy.ps1 на «сервере», который эта же машина: поддельные ssh и scp (tests/fakes),
# настоящий server/release.sh, настоящий git (временный репозиторий + bare origin), поддельный сервис здоровья.
# Запуск: pwsh -NoProfile -File tests/deploy.e2e.ps1   (код выхода 1, если что-то упало)
# Нужны: pwsh, git, bash, curl, tar, python3.
$ErrorActionPreference = 'Stop'

$kit = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$pwshExe = (Get-Process -Id $PID).Path
$script:failures = 0
$script:passed = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if ($Condition) { $script:passed++ }
    else { $script:failures++; Write-Host "FAIL: $Message" -ForegroundColor Red }
}
function Assert-Equal($Actual, $Expected, [string]$Message) { Assert-True ($Actual -eq $Expected) "$Message (получено '$Actual', ожидалось '$Expected')" }
function Assert-Match([string]$Text, [string]$Pattern, [string]$Message) { Assert-True ($Text -match $Pattern) "$Message (нет '$Pattern' в выводе)" }
function Assert-NoMatch([string]$Text, [string]$Pattern, [string]$Message) { Assert-True ($Text -notmatch $Pattern) "$Message (есть '$Pattern' в выводе)" }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("deploy-e2e-" + [guid]::NewGuid().ToString('N'))
$remote = Join-Path $tmp 'remote'
$repo = Join-Path $tmp 'repo'
$origin = Join-Path $tmp 'origin.git'
$log = Join-Path $tmp 'fake.log'
[void][System.IO.Directory]::CreateDirectory($remote)
$health = $null

function Invoke-Git { param([Parameter(ValueFromRemainingArguments)]$GitArgs) & git -C $repo @GitArgs 2>&1 | Out-Null; if ($LASTEXITCODE -ne 0) { throw "git ${GitArgs}: код $LASTEXITCODE" } }
function Get-GitOut { param([Parameter(ValueFromRemainingArguments)]$GitArgs) (& git -C $repo @GitArgs 2>&1) -join "`n" }
function Head { (Get-GitOut rev-parse HEAD).Trim() }
function Marker { Get-Content -LiteralPath (Join-Path $repo 'deploy/deployed.json') -Raw -Encoding UTF8 | ConvertFrom-Json }
function Current([string]$Artifact) { $l = Join-Path $remote "$Artifact/current"; if (Test-Path $l) { (Get-Item $l).ResolvedTarget -replace '.*/' } else { '' } }
function ReleaseCount([string]$Artifact) { @(Get-ChildItem (Join-Path $remote "$Artifact/releases") -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '\.failed$' }).Count }
function ServedCommit([string]$Artifact) { (Get-Content (Join-Path $remote "$Artifact/current/version.json") -Raw | ConvertFrom-Json).commit }

function Invoke-Deploy([string[]]$Arguments = @()) {
    Start-Sleep -Milliseconds 1100   # имя релиза строится из секунд: два запуска подряд не должны совпасть
    $out = & $pwshExe -NoProfile -File (Join-Path $repo 'scripts/deploy.ps1') @Arguments 2>&1 | ForEach-Object { "$_" }
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out -join "`n") }
}

try {
    # ------------------------------------------------------------ сервис здоровья
    $py = (Get-Command python3 -ErrorAction SilentlyContinue)
    if (-not $py) { $py = Get-Command python }
    $psi = New-Object System.Diagnostics.ProcessStartInfo($py.Source, "`"$(Join-Path $kit 'tests/fakes/health_server.py')`" `"$remote`"")
    $psi.RedirectStandardOutput = $true
    $psi.UseShellExecute = $false
    $health = [System.Diagnostics.Process]::Start($psi)
    $port = [int]$health.StandardOutput.ReadLine()

    # ------------------------------------------------------------ «сервер»: каталоги артефактов и release.sh
    [void][System.IO.Directory]::CreateDirectory((Join-Path $remote 'bin'))
    foreach ($name in 'backend', 'frontend') {
        $root = Join-Path $remote $name
        [void][System.IO.Directory]::CreateDirectory($root)
        Set-Content -LiteralPath (Join-Path $root 'release.env') -Encoding ASCII -Value @(
            "HEALTH_URL=http://127.0.0.1:$port/$name/health", 'HEALTH_WAIT=4', 'HEALTH_INTERVAL=0.2', 'KEEP_RELEASES=3')
        Copy-Item (Join-Path $kit 'server/release.sh') (Join-Path $remote "bin/release-$name.sh")
        & chmod +x (Join-Path $remote "bin/release-$name.sh")
    }

    # ------------------------------------------------------------ рабочий репозиторий с origin
    & git init -q --bare $origin
    [void][System.IO.Directory]::CreateDirectory((Join-Path $repo 'scripts/guards'))
    [void][System.IO.Directory]::CreateDirectory((Join-Path $repo 'server'))
    foreach ($f in 'deploy.ps1', 'lib-backup.ps1', 'lib-deploy.ps1', 'version-stamp.ps1', 'checks.py', 'deployed.py', 'check_secrets.py') {
        Copy-Item (Join-Path $kit "scripts/$f") (Join-Path $repo "scripts/$f")
    }
    Copy-Item (Join-Path $kit 'server/release.sh') (Join-Path $repo 'server/release.sh')
    Copy-Item (Join-Path $kit '.gitignore') (Join-Path $repo '.gitignore')
    Set-Content -LiteralPath (Join-Path $repo 'app.txt') -Value 'v1'
    $build = 'Set-Content -LiteralPath (Join-Path $env:STAGE_DIR app.txt) -Value $env:RELEASE_STAMP; if ($env:E2E_FAIL_BUILD -eq ''1'' -or $env:E2E_FAIL_ARTIFACT -eq $env:DEPLOY_ARTIFACT) { exit 3 }; if ($env:E2E_BAD -ne ''1'') { Set-Content -LiteralPath (Join-Path $env:STAGE_DIR healthy) -Value ok }'
    Set-Content -LiteralPath (Join-Path $repo 'scripts/project.conf') -Encoding UTF8 -Value @(
        'SERVER_HOST=testhost', 'PYTHON_CMD=python3', 'DEPLOY_ARTIFACTS=backend,frontend',
        'backend.SSH_USER=deploy', "backend.REMOTE_DIR=$remote/backend", "backend.RELEASE_SCRIPT=$remote/bin/release-backend.sh",
        "backend.HEALTH_URL=http://127.0.0.1:$port/backend/health", "backend.BUILD_CMD=$build",
        'frontend.SSH_USER=deploy', "frontend.REMOTE_DIR=$remote/frontend", "frontend.RELEASE_SCRIPT=$remote/bin/release-frontend.sh",
        "frontend.HEALTH_URL=http://127.0.0.1:$port/frontend/health", "frontend.BUILD_CMD=$build")
    & git -C $repo init -q -b main
    & git -C $repo config user.email 'e2e@example.invalid'
    & git -C $repo config user.name 'e2e'
    & git -C $repo remote add origin $origin
    Invoke-Git add -A
    Invoke-Git commit -q -m 'первый'
    Invoke-Git push -q -u origin main

    # Права на исполнение теряются, когда файлы проходят через Windows и zip: восстанавливаем сами.
    foreach ($f in 'ssh', 'scp', 'health_server.py') { & chmod +x (Join-Path $kit "tests/fakes/$f") }
    $env:PATH = "$(Join-Path $kit 'tests/fakes')$([System.IO.Path]::PathSeparator)$env:PATH"
    $env:FAKE_LOG = $log
    $env:GIT_AUTHOR_NAME = 'e2e'; $env:GIT_AUTHOR_EMAIL = 'e2e@example.invalid'
    $env:GIT_COMMITTER_NAME = 'e2e'; $env:GIT_COMMITTER_EMAIL = 'e2e@example.invalid'

    # ================================================================ 1. успешная выкатка двух артефактов
    $first = Head
    $r = Invoke-Deploy
    Assert-Equal $r.Code 0 '1: выкатка прошла'
    Assert-Match $r.Text 'ВЫКАЧЕНО: backend, frontend' '1: итог называет оба артефакта'
    Assert-Equal (ReleaseCount 'backend') 1 '1: релиз бэкенда на сервере'
    Assert-Equal (ReleaseCount 'frontend') 1 '1: релиз фронта на сервере'
    Assert-Equal (ServedCommit 'backend') $first '1: штамп версии в релизе бэкенда совпадает с HEAD'
    Assert-Match $r.Text 'на сервере [0-9a-f]{7}, тот коммит, из которого собирали' '1: сверка версии после выкатки'
    $m = Marker
    Assert-Equal $m.backend.commit $first '1: маркер бэкенда'
    Assert-Equal $m.frontend.commit $first '1: маркер фронта'
    Assert-Equal ([bool]$m.backend.dirty) $false '1: dirty=false на чистом дереве'
    Assert-Equal (@($m.history).Count) 1 '1: одна запись истории'
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $repo 'deploy/deployed.json'))
    Assert-True (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)) '1: маркер записан без BOM'
    Assert-Equal (Get-GitOut status --porcelain).Trim() '' '1: после выкатки дерево чистое (маркер закоммичен)'
    Assert-Equal (Get-GitOut rev-list --count '@{u}..HEAD').Trim() '0' '1: маркер запушен'
    Assert-Match (Get-GitOut log -1 --format=%s) 'Выкатка .*backend, frontend' '1: сообщение коммита маркера'
    $dep = (& python3 (Join-Path $repo 'scripts/deployed.py')) -join "`n"
    Assert-Match $dep 'Не выкачено: ничего' '1: deployed.py после выкатки не видит невыкаченного'
    Assert-Match $r.Text 'release.sh совпадает с репозиторием' '1: серверный release.sh сверен по хешу'
    Assert-True (Test-Path (Join-Path $repo '.deploy-logs')) '1: журнал выкатки лежит на диске'
    Assert-Equal @(Get-ChildItem $repo -Filter '*.tgz' -Force).Count 0 '1: архивы после выкатки убраны'
    Assert-True (-not (Test-Path (Join-Path $repo '.deploy-stage-backend'))) '1: каталог сборки убран'

    # ================================================================ 2. -WhatIf ничего не меняет
    Set-Content (Join-Path $repo 'app.txt') 'v2'; Invoke-Git add -A; Invoke-Git commit -q -m 'правка 2'; Invoke-Git push -q
    $beforeB = ReleaseCount 'backend'
    $r = Invoke-Deploy @('-WhatIf')
    Assert-Equal $r.Code 0 '2: WhatIf'
    Assert-Match $r.Text 'ПЛАН \(ничего не делается\)' '2: план напечатан'
    Assert-Match $r.Text 'сторожа дерева прошли' '2: проверки в плане настоящие'
    Assert-Equal (ReleaseCount 'backend') $beforeB '2: на сервер ничего не залито'
    Assert-Equal (Marker).backend.commit $first '2: маркер не тронут'

    # ================================================================ 3. грязное дерево: отказ, и -Force
    Set-Content (Join-Path $repo 'wip.txt') 'чужая работа'
    $r = Invoke-Deploy
    Assert-Equal $r.Code 1 '3: грязное дерево отказ'
    Assert-Match $r.Text 'ВЫКАТКА ОСТАНОВЛЕНА' '3: разбор отказа'
    Assert-Match $r.Text 'wip.txt' '3: в разборе названы файлы'
    Assert-Match $r.Text 'Прод не тронут' '3: итог говорит, что прод не тронут'
    Assert-Equal (ReleaseCount 'backend') $beforeB '3: на сервер ничего не залито'
    $r = Invoke-Deploy @('-Force', '-Only', 'backend')
    Assert-Equal $r.Code 0 '3: -Force выкатывает'
    Assert-Match $r.Text 'НА ПРОД УЕЗЖАЕТ НЕ ТО, ЧТО В РЕПОЗИТОРИИ' '3: -Force кричит'
    Assert-Match $r.Text 'ГРЯЗНОЕ ДЕРЕВО' '3: итог помечает грязное дерево'
    Assert-Equal ([bool](Marker).backend.dirty) $true '3: dirty=true в маркере'
    Assert-Equal (Marker).frontend.commit $first '3: фронт не выкатывался, его запись прежняя'
    Remove-Item (Join-Path $repo 'wip.txt')

    # ================================================================ 4. незапушенный коммит
    Set-Content (Join-Path $repo 'app.txt') 'v3'; Invoke-Git add -A; Invoke-Git commit -q -m 'не запушено'
    $r = Invoke-Deploy
    Assert-Equal $r.Code 1 '4: незапушенный коммит отказ'
    Assert-Match $r.Text 'не запушены' '4: сказано про push'
    Invoke-Git push -q

    # ================================================================ 5. сторож дерева
    Set-Content (Join-Path $repo 'scripts/guards/10-stop.py') -Value @('# about: нет файла STOP', 'import sys, pathlib', 'root = pathlib.Path(__file__).resolve().parent.parent.parent', 'if (root / "STOP").exists():', '    print("ПЛОХО: лежит STOP"); sys.exit(1)')
    Set-Content (Join-Path $repo 'STOP') 'x'
    Invoke-Git add -A; Invoke-Git commit -q -m 'сторож и STOP'; Invoke-Git push -q
    $r = Invoke-Deploy
    Assert-Equal $r.Code 1 '5: красный сторож останавливает выкатку'
    Assert-Match $r.Text 'ПЛОХО: лежит STOP' '5: причина названа'
    Invoke-Git rm -q STOP; Invoke-Git commit -q -m 'убрали STOP'; Invoke-Git push -q

    # ================================================================ 6. сборка упала
    $env:E2E_FAIL_BUILD = '1'
    $beforeB = ReleaseCount 'backend'
    $r = Invoke-Deploy
    Remove-Item Env:E2E_FAIL_BUILD
    Assert-Equal $r.Code 1 '6: упавшая сборка'
    Assert-Match $r.Text 'сборка backend вернула код 3' '6: причина названа'
    Assert-Equal (ReleaseCount 'backend') $beforeB '6: на сервер ничего не залито'
    Assert-Match $r.Text 'Новый релиз не принят' '6: итог'

    # ================================================================ 6б. первый артефакт уехал, у второго упала сборка
    $h6 = Head
    $env:E2E_FAIL_ARTIFACT = 'frontend'
    $r = Invoke-Deploy
    Remove-Item Env:E2E_FAIL_ARTIFACT
    Assert-Equal $r.Code 1 '6б: сборка второго артефакта упала'
    Assert-Equal (Marker).backend.commit $h6 '6б: маркер бэкенда записан — он уехал'
    Assert-True ((Marker).frontend.commit -ne $h6) '6б: маркер фронта не тронут — он не уехал'

    # ================================================================ 7. ssh упал на приёме: ничего не уехало
    $m0 = (Marker).history.Count
    $env:FAKE_SSH_FAIL_MATCH = ' receive '
    $r = Invoke-Deploy
    Remove-Item Env:FAKE_SSH_FAIL_MATCH
    Assert-Equal $r.Code 1 '7: обрыв приёма'
    Assert-Equal (Marker).history.Count $m0 '7: маркер не записан, раз ничего не уехало'
    Assert-Equal (Get-GitOut status --porcelain).Trim() '' '7: дерево осталось чистым'

    # ================================================================ 8. второй артефакт не поднялся: откат сервером, маркер по факту
    $good = Head
    $r = Invoke-Deploy
    Assert-Equal $r.Code 0 '8: хорошая выкатка перед плохой'
    $frontBefore = Current 'frontend'
    Set-Content (Join-Path $repo 'app.txt') 'v5'; Invoke-Git add -A; Invoke-Git commit -q -m 'правка 5'; Invoke-Git push -q
    $badHead = Head
    $r1 = Invoke-Deploy @('-Only', 'backend')
    Assert-Equal $r1.Code 0 '8: бэкенд новой версии'
    $env:E2E_BAD = '1'
    $r2 = Invoke-Deploy @('-Only', 'frontend')
    Remove-Item Env:E2E_BAD
    Assert-Equal $r2.Code 1 '8: фронт не поднялся'
    Assert-Match $r2.Text 'здоровье не подтвердилось' '8: приём сказал причину'
    Assert-Equal (Current 'frontend') $frontBefore '8: сервер сам вернул фронт на прежний релиз'
    Assert-True (@(Get-ChildItem (Join-Path $remote 'frontend/releases') -Directory | Where-Object { $_.Name -match '\.failed$' }).Count -ge 1) '8: неудачный релиз оставлен для разбора'
    Assert-Equal (Marker).backend.commit $badHead '8: маркер бэкенда на новом коммите'
    Assert-Equal (Marker).frontend.commit $good '8: маркер фронта остался на прежнем (откат сервером)'
    $dep = (& python3 (Join-Path $repo 'scripts/deployed.py')) -join "`n"
    Assert-Match $dep 'считаем от отставшего: frontend' '8: deployed.py считает от отставшего'

    # ================================================================ 9. ручной откат
    $backNew = Current 'backend'
    $r = Invoke-Deploy @('-Rollback', 'backend')
    Assert-Equal $r.Code 0 '9: откат'
    Assert-True ((Current 'backend') -ne $backNew) '9: симлинк бэкенда переключён'
    Assert-Match $r.Text 'Схема базы осталась новой' '9: напоминание про схему базы'
    Assert-Equal (Marker).backend.commit (ServedCommit 'backend') '9: маркер записан по версии, которую отдаёт сервер'
    Assert-Match (Get-GitOut log -1 --format=%s) 'Откат' '9: коммит маркера назван откатом'

    # ================================================================ 10. -MarkOnly пишет только то, что подтвердил сервер
    $r = Invoke-Deploy @('-Only', 'frontend')
    Assert-Equal $r.Code 0 '10: фронт до HEAD'
    Invoke-Git rm -q deploy/deployed.json; Invoke-Git commit -q -m 'без маркера'; Invoke-Git push -q
    # Выкатка, оборвавшаяся до записи маркера, оставляет сервер ровно на HEAD. Воспроизводим это прямо:
    # версия, которую отдаёт сервер фронта, становится равной HEAD дерева.
    $vf = Join-Path $remote 'frontend/current/version.json'
    $v = Get-Content $vf -Raw | ConvertFrom-Json
    $v.commit = Head; $v.commit_short = (Head).Substring(0, 7)
    Set-Content -LiteralPath $vf -Value ($v | ConvertTo-Json)
    $r = Invoke-Deploy @('-MarkOnly')
    Assert-Equal $r.Code 0 '10: MarkOnly'
    Assert-Match $r.Text 'backend: на сервере [0-9a-f]{7}, в дереве [0-9a-f]{7}: не пишем' '10: бэкенд (откачен) не совпал с деревом'
    $m = Marker
    Assert-True ($null -ne $m.frontend) '10: фронт записан'
    Assert-True ($null -eq $m.backend) '10: бэкенд не записан, сервер его не подтвердил'

    # ================================================================ 11. release.sh с CRLF не уезжает на сервер, выкатка не падает
    $rs = Join-Path $repo 'server/release.sh'
    [System.IO.File]::WriteAllText($rs, ([System.IO.File]::ReadAllText($rs) -replace "`n", "`r`n"))
    Invoke-Git add -A; Invoke-Git commit -q -m 'release.sh с CRLF'; Invoke-Git push -q
    $r = Invoke-Deploy @('-Only', 'frontend')
    Assert-Equal $r.Code 0 '11: выкатка прошла'
    Assert-Match $r.Text 'концы строк CRLF' '11: беда с release.sh названа'
    Assert-Match $r.Text 'ВНИМАНИЕ: release.sh на сервере не обновлён' '11: она поднята в итоговый блок'

    # ================================================================ 12. неизвестный артефакт и конфигурация
    $r = Invoke-Deploy @('-Only', 'nope')
    Assert-Equal $r.Code 1 '12: неизвестный артефакт'
    Assert-Match $r.Text 'нет такого артефакта' '12: сказано, что именно'
}
finally {
    if ($health -and -not $health.HasExited) { $health.Kill() }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "прошло: $script:passed, упало: $script:failures"
if ($script:failures -gt 0) { exit 1 }
