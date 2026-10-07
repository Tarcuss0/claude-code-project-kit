# git bundle репозиториев в хранилище бэкапов на ПК (раз в сутки на репозиторий).
# Запуск: .\scripts\bundle-repos.ps1            -WhatIf показывает план
# Репозитории берутся из LOCAL_REPOS в project.conf (через ;).
# Бандл создаётся во временный файл, проверяется git bundle verify и только потом
# получает рабочее имя. Чистятся только свои файлы вида <имя>-yyyyMMdd.bundle.
# Файл сохранён как UTF-8 with BOM.
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'project.conf'),
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib-backup.ps1')

$conf = Read-Conf $ConfigPath
foreach ($key in 'PROJECT_SLUG', 'LOCAL_BACKUP_ROOT', 'LOCAL_REPOS') {
    if (-not $conf[$key]) { throw "в project.conf не задан $key" }
}
$dest = Join-Path (Join-Path $conf['LOCAL_BACKUP_ROOT'] $conf['PROJECT_SLUG']) 'repo'
$keep = if ($conf['KEEP_BUNDLES']) { [int]$conf['KEEP_BUNDLES'] } else { 14 }
$repos = @($conf['LOCAL_REPOS'] -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

if ($WhatIf) {
    Write-Host 'ПЛАН (ничего не делается)' -ForegroundColor Yellow
    Write-Host "  куда:  $dest (последние $keep на репозиторий)"
    foreach ($r in $repos) { Write-Host "  репозиторий: $r" }
    exit 0
}

[void][System.IO.Directory]::CreateDirectory($dest)
$today = Get-Date -Format 'yyyyMMdd'
$failed = 0

foreach ($repo in $repos) {
    if (-not (Test-Path -LiteralPath (Join-Path $repo '.git'))) {
        Write-Host "пропуск: $repo не репозиторий" -ForegroundColor Yellow
        continue
    }
    $name = Split-Path -Leaf $repo
    $target = Join-Path $dest "$name-$today.bundle"
    if (Test-Path -LiteralPath $target) {
        Write-Host "${name}: сегодняшний бандл уже есть" -ForegroundColor Green
    } else {
        $tmp = "$target.part"
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
        $make = Invoke-Native { git -C $repo bundle create $tmp --all }
        if ($make.Code -ne 0) {
            Write-Host "${name}: git bundle create не прошёл" -ForegroundColor Red
            $failed++
            continue
        }
        $check = Invoke-Native { git -C $repo bundle verify $tmp }
        if ($check.Code -ne 0) {
            Remove-Item -LiteralPath $tmp -Force
            Write-Host "${name}: git bundle verify не прошёл, бандл отброшен" -ForegroundColor Red
            $failed++
            continue
        }
        Move-Item -LiteralPath $tmp -Destination $target
        Write-Host "${name}: бандл создан и проверен" -ForegroundColor Green
    }

    Get-ChildItem -LiteralPath $dest -Filter "$name-*.bundle" -File |
        Where-Object { $_.Name -match ('^' + [regex]::Escape($name) + '-\d{8}\.bundle$') } |
        Sort-Object Name -Descending |
        Select-Object -Skip $keep |
        Remove-Item -Force
}

if ($failed -gt 0) { exit 1 }
exit 0
