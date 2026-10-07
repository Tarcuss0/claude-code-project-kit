# Создаёт задачу планировщика Windows: забор снимка базы и бандлы репозиториев каждые 2 часа.
# Пропущенный запуск догоняется. Запускать один раз от администратора:
# powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-backup-task.ps1
#
# Важно: ключ сервера должен лежать в ssh-агенте пользователя, под которым идёт задача
# (ssh-add -l). Без него BatchMode=yes откажет без вопроса, и задача завершится кодом 1.
# Файл сохранён как UTF-8 with BOM.
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'project.conf')
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib-backup.ps1')

$conf = Read-Conf $ConfigPath
$slug = $conf['PROJECT_SLUG']
if (-not $slug) { throw 'PROJECT_SLUG не задан в project.conf' }

$taskName = "$slug-backup"
$pull   = Join-Path $PSScriptRoot 'pull-backup.ps1'
$bundle = Join-Path $PSScriptRoot 'bundle-repos.ps1'

$actions = @(
    (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$pull`"")
)
if ($conf['LOCAL_REPOS']) {
    $actions += New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$bundle`""
}

$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Hours 2)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1)

Register-ScheduledTask -TaskName $taskName -Action $actions -Trigger $trigger -Settings $settings -Force | Out-Null

Write-Output "задача создана: $taskName (каждые 2 часа, пропущенный запуск догоняется)"
Write-Output "запустить сейчас:  Start-ScheduledTask -TaskName $taskName"
Write-Output "последний запуск:  Get-ScheduledTaskInfo -TaskName $taskName"
