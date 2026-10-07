# Deploy skeleton. You run it yourself, by hand, after git push. Claude Code sessions never run it.
# Запуск: .\scripts\deploy.ps1            (без полного прогона тестов)
#         .\scripts\deploy.ps1 -WithTests (с полным прогоном тестов на ПК)
# Команды проекта берутся из project.conf: TEST_CMD, MIGRATE_CMD, VERSION_CMD.
# Файл сохранён как UTF-8 with BOM.
param(
    [switch]$WithTests   # полный набор тестов перед выкаткой. По умолчанию выключен: слишком долго
)
$ErrorActionPreference = 'Stop'

function Read-Conf([string]$Path) {
    $h = @{}
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $i = $t.IndexOf('=')
        if ($i -gt 0) { $h[$t.Substring(0, $i).Trim()] = $t.Substring($i + 1).Trim() }
    }
    return $h
}
function Fail([string]$m) { Write-Host "STOP: $m" -ForegroundColor Red; exit 1 }
function Step([string]$m) { Write-Host "== $m" -ForegroundColor Cyan }

$conf = Read-Conf (Join-Path $PSScriptRoot 'project.conf')
$remote = "$($conf['SERVER_USER'])@$($conf['SERVER_HOST'])"
$appDir = $conf['SERVER_APP_DIR']
$service = $conf['SERVICE_NAME']
$healthz = $conf['HEALTHZ_URL']

function Rollback([string]$prev) {
    Write-Host "откат на $prev" -ForegroundColor Red
    ssh $remote "cd $appDir && git checkout $prev && systemctl restart $service"
    Fail 'выкатка отменена, версия на сервере возвращена'
}

Step '1. Дерево чистое, локальный коммит запушен'
$dirty = git status --porcelain
if ($dirty) { Fail "в дереве есть незакоммиченные изменения:`n$dirty" }
git fetch origin 2>&1 | Out-Null
$ahead = git rev-list --count '@{u}..HEAD'
if ([int]$ahead -gt 0) { Fail "есть $ahead незапушенных коммитов: сначала git push" }

Step '2. Секреты'
python scripts/check_secrets.py
if ($LASTEXITCODE -ne 0) { Fail 'check_secrets нашёл проблемы' }

Step '3. Полный набор тестов (только с ключом -WithTests)'
if ($WithTests) {
    if (-not $conf['TEST_CMD']) { Fail 'TEST_CMD не задан в project.conf' }
    Invoke-Expression $conf['TEST_CMD']
    if ($LASTEXITCODE -ne 0) { Fail 'полный набор тестов упал, выкатка отменена' }
} else {
    Write-Host 'полный набор тестов пропущен (так задумано, запуск с -WithTests включает его)'
}

Step '4. Текущая версия на сервере (для отката)'
$prev = (ssh $remote "cd $appDir && git rev-parse HEAD").Trim()
if (-not $prev) { Fail 'не удалось узнать текущий коммит на сервере' }
Write-Host "на сервере сейчас: $prev"
$new = (git rev-parse HEAD).Trim()
Write-Host "выкатываем:         $new"

Step '5. Выкатка'
ssh $remote "cd $appDir && git pull --ff-only"
if ($LASTEXITCODE -ne 0) { Fail 'git pull на сервере не прошёл' }

if ($conf['MIGRATE_CMD']) {
    ssh $remote "cd $appDir && $($conf['MIGRATE_CMD'])"
    if ($LASTEXITCODE -ne 0) { Rollback $prev }
}

ssh $remote "systemctl restart $service"
if ($LASTEXITCODE -ne 0) { Rollback $prev }

Step '6. Проверка здоровья (до 120 секунд)'
$ok = $false
for ($i = 0; $i -lt 24; $i++) {
    Start-Sleep -Seconds 5
    $code = ssh $remote "curl -s -o /dev/null -w '%{http_code}' $healthz"
    if ($code -eq '200') { $ok = $true; break }
}
if (-not $ok) { Write-Host 'healthz не ответил 200' -ForegroundColor Red; Rollback $prev }

Step '7. Версия миграций'
if ($conf['VERSION_CMD']) {
    ssh $remote "cd $appDir && $($conf['VERSION_CMD'])"
}

Write-Host "готово: $new" -ForegroundColor Green
