# Тесты функций scripts/lib-deploy.ps1 без сети и без Pester: git во временных репозиториях,
# ssh и scp подменены функциями. Запуск: pwsh -NoProfile -File tests/lib-deploy.tests.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'scripts' 'lib-backup.ps1')
. (Join-Path $PSScriptRoot '..' 'scripts' 'lib-deploy.ps1')
$kit = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

$script:failures = 0
$script:passed = 0
function Assert-True([bool]$Condition, [string]$Message) {
    if ($Condition) { $script:passed++ } else { $script:failures++; Write-Host "FAIL: $Message" -ForegroundColor Red }
}
function Assert-Equal($Actual, $Expected, [string]$Message) { Assert-True ($Actual -eq $Expected) "$Message (получено '$Actual', ожидалось '$Expected')" }
function Assert-Throws([scriptblock]$Block, [string]$Pattern, [string]$Message) {
    $threw = $false
    try { & $Block } catch { $threw = $true; Assert-True ($_.Exception.Message -match $Pattern) "$Message (текст ошибки: $($_.Exception.Message))" }
    if (-not $threw) { Assert-True $false "$Message (исключения не было)" }
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("lib-deploy-tests-" + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($tmp)
$env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@example.invalid'
$env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@example.invalid'

function New-RepoPair([string]$Name) {
    $origin = Join-Path $tmp "$Name-origin.git"
    $work = Join-Path $tmp $Name
    & git init -q --bare -b main $origin
    & git init -q -b main $work
    & git -C $work remote add origin $origin
    Set-Content (Join-Path $work 'a.txt') '1'
    & git -C $work add -A
    & git -C $work commit -q -m first
    & git -C $work push -q -u origin main 2>$null
    return [pscustomobject]@{ Work = $work; Origin = $origin }
}
function Add-Commit([string]$Work, [string]$Text) {
    Set-Content (Join-Path $Work 'a.txt') $Text
    & git -C $Work add -A
    & git -C $Work commit -q -m $Text
}

try {
    # ---------------- Get-Artifacts
    $base = @{ DEPLOY_ARTIFACTS = 'backend, frontend'
        'backend.SSH_USER' = 'root'; 'backend.REMOTE_DIR' = '/srv/b'; 'backend.BUILD_CMD' = 'b'; 'backend.RELEASE_SCRIPT' = '/usr/local/sbin/rel'
        'frontend.SSH_USER' = 'web'; 'frontend.REMOTE_DIR' = '/srv/f'; 'frontend.BUILD_CMD' = 'f'; 'frontend.RECEIVER' = '/x/recv --root /srv/f'; 'frontend.HEALTH_URL' = 'http://h' }
    $arts = Get-Artifacts $base
    Assert-Equal $arts.Count 2 'Get-Artifacts: два артефакта'
    Assert-Equal $arts[0].Name 'backend' 'Get-Artifacts: порядок как в конфигурации'
    Assert-Equal $arts[0].Receiver '/usr/local/sbin/rel --root /srv/b' 'Get-Artifacts: приём по умолчанию из RELEASE_SCRIPT и REMOTE_DIR'
    Assert-Equal $arts[1].Receiver '/x/recv --root /srv/f' 'Get-Artifacts: явный RECEIVER сильнее'
    Assert-Equal $arts[1].HealthUrl 'http://h' 'Get-Artifacts: HEALTH_URL'
    Assert-Equal $arts[0].HealthUrl '' 'Get-Artifacts: HEALTH_URL пустой, если не задан'
    Assert-Throws { Get-Artifacts @{} } 'DEPLOY_ARTIFACTS' 'Get-Artifacts: без списка отказ'
    $bad = $base.Clone(); $bad.Remove('backend.REMOTE_DIR')
    Assert-Throws { Get-Artifacts $bad } 'backend.REMOTE_DIR' 'Get-Artifacts: нет REMOTE_DIR'
    $bad = $base.Clone(); $bad.Remove('backend.BUILD_CMD')
    Assert-Throws { Get-Artifacts $bad } 'backend.BUILD_CMD' 'Get-Artifacts: нет BUILD_CMD'
    $bad = $base.Clone(); $bad.Remove('backend.RELEASE_SCRIPT')
    Assert-Throws { Get-Artifacts $bad } 'RELEASE_SCRIPT или backend.RECEIVER|RECEIVER' 'Get-Artifacts: нет ни RELEASE_SCRIPT, ни RECEIVER'
    $bad = $base.Clone(); $bad.DEPLOY_ARTIFACTS = 'bad name'
    Assert-Throws { Get-Artifacts $bad } 'недопустимое имя' 'Get-Artifacts: имя с пробелом'
    $bad = $base.Clone(); $bad.DEPLOY_ARTIFACTS = '../x'
    Assert-Throws { Get-Artifacts $bad } 'недопустимое имя' 'Get-Artifacts: имя с точками'

    # ---------------- Test-Origin: все шесть состояний
    $p = New-RepoPair 'ok'
    Assert-Equal (Test-Origin -Repo $p.Work).state 'ok' 'Test-Origin: совпадает'
    Add-Commit $p.Work 'local'
    $o = Test-Origin -Repo $p.Work
    Assert-Equal $o.state 'ahead' 'Test-Origin: впереди'
    Assert-Equal $o.ahead 1 'Test-Origin: число коммитов впереди'

    $p = New-RepoPair 'behind'
    $other = Join-Path $tmp 'behind-other'
    & git clone -q $p.Origin $other
    Add-Commit $other 'theirs'
    & git -C $other push -q 2>$null
    $o = Test-Origin -Repo $p.Work
    Assert-Equal $o.state 'behind' 'Test-Origin: отстала'
    Assert-Equal $o.behind 1 'Test-Origin: число отставаний'

    Add-Commit $p.Work 'mine'
    Assert-Equal (Test-Origin -Repo $p.Work).state 'diverged' 'Test-Origin: разошлись'

    $p = New-RepoPair 'noup'
    & git -C $p.Work branch --unset-upstream
    Assert-Equal (Test-Origin -Repo $p.Work).state 'no-upstream' 'Test-Origin: нет upstream'

    $p = New-RepoPair 'offline'
    & git -C $p.Work remote set-url origin (Join-Path $tmp 'no-such-origin.git')
    Assert-Equal (Test-Origin -Repo $p.Work).state 'offline' 'Test-Origin: origin не ответил это не «не запушено»'
    Add-Commit $p.Work 'local while offline'
    Assert-Equal (Test-Origin -Repo $p.Work).state 'offline' 'Test-Origin: офлайн остаётся офлайном, даже если есть локальные коммиты'

    # ---------------- Assert-Deployable
    $p = New-RepoPair 'deployable'
    $res = Assert-Deployable -Repo $p.Work 6>$null
    Assert-True ($res.Ok -and -not $res.Forced) 'Assert-Deployable: чистое дерево проходит'
    Set-Content (Join-Path $p.Work 'wip.txt') 'x'
    Assert-Throws { Assert-Deployable -Repo $p.Work 6>$null } 'Дерево не готово' 'Assert-Deployable: грязное дерево отказ'
    $res = Assert-Deployable -Repo $p.Work -Force 6>$null
    Assert-True ($res.Ok -and $res.Forced) 'Assert-Deployable: -Force пропускает и помечает'
    Assert-Equal $res.Dirty.Count 1 'Assert-Deployable: -Force знает грязные файлы'
    Remove-Item (Join-Path $p.Work 'wip.txt')
    Add-Commit $p.Work 'unpushed'
    Assert-Throws { Assert-Deployable -Repo $p.Work 6>$null } 'Дерево не готово' 'Assert-Deployable: незапушенное отказ'

    # ---------------- Write-Marker
    $p = New-RepoPair 'marker'
    $e1 = @{ commit = 'a' * 40; commit_short = 'aaaaaaa'; release = 'r1'; branch = 'main'; dirty = $false; deployed_at = 'now' }
    $res = Write-Marker -Root $p.Work -Entries @{ backend = $e1 } -Stamp 'r1' 6>$null
    Assert-True $res.Committed 'Write-Marker: закоммичен'
    Assert-True $res.Pushed 'Write-Marker: запушен'
    $file = Join-Path $p.Work 'deploy/deployed.json'
    $bytes = [System.IO.File]::ReadAllBytes($file)
    Assert-True (-not ($bytes[0] -eq 0xEF)) 'Write-Marker: без BOM'
    $e2 = @{ commit = 'b' * 40; commit_short = 'bbbbbbb'; release = 'r2'; branch = 'main'; dirty = $true; deployed_at = 'now' }
    [void](Write-Marker -Root $p.Work -Entries @{ frontend = $e2 } -Stamp 'r2' 6>$null)
    $m = Get-Content $file -Raw | ConvertFrom-Json
    Assert-Equal $m.backend.commit ('a' * 40) 'Write-Marker: прежняя запись артефакта сохранилась'
    Assert-Equal $m.frontend.commit ('b' * 40) 'Write-Marker: новая запись добавлена'
    Assert-Equal ([bool]$m.frontend.dirty) $true 'Write-Marker: dirty записан'
    Assert-Equal @($m.history).Count 2 'Write-Marker: история растёт'
    Assert-Equal $m.history[0].release 'r2' 'Write-Marker: новые записи истории сверху'
    for ($i = 3; $i -le 30; $i++) { [void](Write-Marker -Root $p.Work -Entries @{ backend = $e1 } -Stamp "r$i" 6>$null) }
    $m = Get-Content $file -Raw | ConvertFrom-Json
    Assert-Equal @($m.history).Count 20 'Write-Marker: история обрезана до двадцати'
    Assert-Equal $m.history[0].release 'r30' 'Write-Marker: сверху самая свежая'
    Assert-Equal (& git -C $p.Work status --porcelain) $null 'Write-Marker: после записи дерево чистое'
    Assert-Equal $null (Write-Marker -Root $p.Work -Entries @{} -Stamp 'x') 'Write-Marker: пустой набор ничего не пишет'
    Set-Content $file 'не json'
    [void](Write-Marker -Root $p.Work -Entries @{ backend = $e1 } -Stamp 'again' 6>$null)
    $m = Get-Content $file -Raw | ConvertFrom-Json
    Assert-Equal $m.backend.commit ('a' * 40) 'Write-Marker: испорченный маркер пересобирается, а не роняет выкатку'

    # маркер, у которого нет origin: коммит есть, пуш не прошёл, выкатку это не роняет
    $p2 = New-RepoPair 'marker-offline'
    & git -C $p2.Work remote set-url origin (Join-Path $tmp 'gone.git')
    $res = Write-Marker -Root $p2.Work -Entries @{ backend = $e1 } -Stamp 'r1' 6>$null
    Assert-True $res.Committed 'Write-Marker: без сети коммит есть'
    Assert-True (-not $res.Pushed) 'Write-Marker: без сети пуш не прошёл и это отмечено'

    # ---------------- Get-RemoteVersion и Confirm-Deployed на подменённом ssh
    $art = [pscustomobject]@{ Name = 'backend'; SshUser = 'u'; HealthUrl = 'http://127.0.0.1/health' }
    $ver = [pscustomobject]@{ commit = 'c' * 40; commit_short = 'ccccccc'; version = 'ccccccc' }
    $script:sshLines = @(); $script:sshCode = 0
    function ssh { $global:LASTEXITCODE = $script:sshCode; return $script:sshLines }

    $script:sshLines = @('Warning: Permanently added host', ('{"status":"ok","version":{"commit":"' + ('c' * 40) + '","commit_short":"ccccccc","version":"ccccccc"}}'))
    $r = Get-RemoteVersion -Artifact $art -Server h
    Assert-Equal $r.Status 'ok' 'Get-RemoteVersion: предупреждение ssh рядом с JSON не мешает'
    Assert-Equal $r.Version.commit ('c' * 40) 'Get-RemoteVersion: коммит прочитан'
    $script:sshLines = @('<html>нет</html>')
    Assert-Equal (Get-RemoteVersion -Artifact $art -Server h).Status 'not-json' 'Get-RemoteVersion: не JSON'
    $script:sshLines = @('{"status":"ok"}')
    Assert-Equal (Get-RemoteVersion -Artifact $art -Server h).Status 'no-version' 'Get-RemoteVersion: нет поля version'
    $script:sshLines = @('{"status":"ok","version":null}')
    Assert-Equal (Get-RemoteVersion -Artifact $art -Server h).Status 'no-version' 'Get-RemoteVersion: version равен null (сборка мимо deploy.ps1)'
    $script:sshCode = 22; $script:sshLines = @('curl: (22) The requested URL returned error: 503')
    Assert-Equal (Get-RemoteVersion -Artifact $art -Server h).Status 'unreachable' 'Get-RemoteVersion: здоровье вернуло 503'
    $script:sshCode = 0
    $noUrl = [pscustomobject]@{ Name = 'x'; SshUser = 'u'; HealthUrl = '' }
    Assert-Equal (Get-RemoteVersion -Artifact $noUrl -Server h).Status 'no-url' 'Get-RemoteVersion: нет HEALTH_URL'

    $script:sshLines = @('{"version":{"commit":"' + ('c' * 40) + '","commit_short":"ccccccc","version":"ccccccc"}}')
    Assert-Equal (Confirm-Deployed -Artifact $art -Server h -Version $ver 6>$null) 'match' 'Confirm-Deployed: тот же коммит'
    $script:sshLines = @('{"version":{"commit":"' + ('d' * 40) + '","commit_short":"ddddddd","version":"ddddddd"}}')
    Assert-Equal (Confirm-Deployed -Artifact $art -Server h -Version $ver 6>$null) 'mismatch' 'Confirm-Deployed: другой коммит на сервере'
    $script:sshLines = @('{"status":"ok"}')
    Assert-Equal (Confirm-Deployed -Artifact $art -Server h -Version $ver 6>$null) 'unverified' 'Confirm-Deployed: версии нет, не проверено'
    Assert-Equal (Confirm-Deployed -Artifact $noUrl -Server h -Version $ver 6>$null) 'unverified' 'Confirm-Deployed: HEALTH_URL не задан, не проверено'
    $script:sshCode = 255
    Assert-Equal (Confirm-Deployed -Artifact $art -Server h -Version $ver 6>$null) 'unverified' 'Confirm-Deployed: обрыв ssh не роняет выкатку'
    $script:sshCode = 0

    # ---------------- Send-ServerScripts на подменённых ssh и scp
    $root = Join-Path $tmp 'ship'
    [void][System.IO.Directory]::CreateDirectory((Join-Path $root 'server'))
    $local = Join-Path $root 'server/release.sh'
    [System.IO.File]::WriteAllText($local, "#!/usr/bin/env bash`necho hi`n")
    $hash = (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash.ToLower()
    $ship = @([pscustomobject]@{ Name = 'backend'; SshUser = 'root'; RemoteDir = '/srv/b'; ReleaseScript = '/usr/local/sbin/rel' },
              [pscustomobject]@{ Name = 'frontend'; SshUser = 'web'; RemoteDir = '/srv/f'; ReleaseScript = '/srv/f/rel' },
              [pscustomobject]@{ Name = 'noscript'; SshUser = 'web'; RemoteDir = '/srv/n'; ReleaseScript = '' })
    $script:calls = @(); $script:scpCode = 0; $script:installCode = 0; $script:remoteHash = $hash
    function scp { $script:calls += "scp $args"; $global:LASTEXITCODE = $script:scpCode }
    function ssh {
        $cmd = "$($args[-1])"
        $script:calls += "ssh $cmd"
        if ($cmd -like 'install*') { $global:LASTEXITCODE = $script:installCode; return }
        if ($cmd -like 'sha256sum*') { $global:LASTEXITCODE = 0; return "$($script:remoteHash)  /x" }
        $global:LASTEXITCODE = 0
    }
    $probs = @(Send-ServerScripts -Root $root -Artifacts $ship -Server h 6>$null)
    Assert-Equal $probs.Count 0 'Send-ServerScripts: всё совпало, бед нет'
    Assert-True ($script:calls -contains 'scp -o BatchMode=yes ' -or ($script:calls | Where-Object { $_ -like '*root@h:/root/release.sh.new*' })) 'Send-ServerScripts: для root промежуточный файл в /root, не в /tmp'
    Assert-True (-not ($script:calls | Where-Object { $_ -like '*h:/tmp/*' -or $_ -like 'ssh install -m 755 /tmp/*' })) 'Send-ServerScripts: на сервере /tmp не используется'
    Assert-True ($null -ne ($script:calls | Where-Object { $_ -like '*web@h:/srv/f/incoming/release.sh.new*' })) 'Send-ServerScripts: для обычного пользователя файл в incoming артефакта'
    Assert-True (-not ($script:calls | Where-Object { $_ -like '*noscript*' -or $_ -like '*/srv/n*' })) 'Send-ServerScripts: артефакт без RELEASE_SCRIPT пропущен'
    $script:remoteHash = 'f' * 64
    $probs = @(Send-ServerScripts -Root $root -Artifacts $ship -Server h 6>$null)
    Assert-Equal $probs.Count 2 'Send-ServerScripts: хеши разошлись у обоих'
    Assert-True ($probs[0] -match 'ДРУГОЙ release.sh') 'Send-ServerScripts: сказано про разные хеши'
    $script:remoteHash = $hash; $script:scpCode = 1
    $probs = @(Send-ServerScripts -Root $root -Artifacts $ship -Server h 6>$null)
    Assert-True ($probs[0] -match 'не залился') 'Send-ServerScripts: scp упал'
    $script:scpCode = 0; $script:installCode = 1
    $probs = @(Send-ServerScripts -Root $root -Artifacts $ship -Server h 6>$null)
    Assert-True ($probs[0] -match 'не установился') 'Send-ServerScripts: install упал'
    $script:installCode = 0
    [System.IO.File]::WriteAllText($local, "#!/usr/bin/env bash`r`necho hi`r`n")
    $script:calls = @()
    $probs = @(Send-ServerScripts -Root $root -Artifacts $ship -Server h 6>$null)
    Assert-True ($probs[0] -match 'CRLF') 'Send-ServerScripts: CRLF не отправляется'
    Assert-Equal $script:calls.Count 0 'Send-ServerScripts: при CRLF на сервер не ходили вообще'
    Remove-Item $local
    $probs = @(Send-ServerScripts -Root $root -Artifacts $ship -Server h 6>$null)
    Assert-True ($probs[0] -match 'нет в репозитории') 'Send-ServerScripts: нет файла в репозитории'
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "прошло: $script:passed, упало: $script:failures"
if ($script:failures -gt 0) { exit 1 }
# Явный код выхода: в CI шаг pwsh берёт $LASTEXITCODE последней внешней команды, а она могла быть ненулевой.
exit 0
