# Штамп версии релиза: какой коммит уехал на сервер.
#
# Отдельным файлом, а не внутри deploy.ps1, по двум причинам: его
# подключают оба артефакта (бэкенд и фронт), и его можно запустить
# руками, не выкатывая ничего:
#
#   . .\scripts\version-stamp.ps1
#   Get-VersionStamp -Root . -Release test | ConvertTo-Json
#
# Файл version.json уезжает внутрь артефакта и остаётся в релизе. Его отдаёт
# проверка здоровья артефакта (полем version), и стенд можно сверить с
# `git log`, не заходя на сервер. Файл сохранён как UTF-8 with BOM.

function Get-VersionStamp {
  <#
    .SYNOPSIS
      Собирает сведения о коммите, из которого собран артефакт.
  #>
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$Release,
    [string]$Component = 'unknown'
  )

  Push-Location $Root
  try {
    $commit = (git rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $commit) {
      throw 'git rev-parse HEAD не отвечает — сборка вне репозитория?'
    }
    $commit = $commit.Trim()
    $branch = (git rev-parse --abbrev-ref HEAD).Trim()

    # Незакоммиченное считаем по --porcelain: он молчит на чистом дереве
    # и печатает по строке на файл на грязном. Файлы из .gitignore сюда
    # не попадают — они не часть кода.
    $changed = @(git status --porcelain | Where-Object { $_ -and $_.Trim() })
    $dirty   = $changed.Count -gt 0

    # Человеку показываем одной строкой: короткий хеш и, если дерево
    # грязное, отметка. Без неё выкаченное невозможно сопоставить с
    # репозиторием: коммит тот, а код другой.
    $short = $commit.Substring(0, 7)
    $label = if ($dirty) { "${short}-dirty" } else { $short }

    [pscustomobject]@{
      component    = $Component
      release      = $Release
      version      = $label
      commit       = $commit
      commit_short = $short
      branch       = $branch
      dirty        = $dirty
      dirty_files  = $changed.Count
      built_at     = (Get-Date).ToString('o')
    }
  }
  finally { Pop-Location }
}

function Write-VersionStamp {
  <#
    .SYNOPSIS
      Кладёт штамп в каталог артефакта файлом version.json.
  #>
  param(
    [Parameter(Mandatory)]$Stamp,
    [Parameter(Mandatory)][string]$Directory
  )

  if (-not (Test-Path $Directory)) {
    New-Item $Directory -ItemType Directory -Force | Out-Null
  }
  $path = Join-Path $Directory 'version.json'
  $json = $Stamp | ConvertTo-Json -Depth 3

  # Без BOM намеренно: файл читают Python и Node, а json.load на BOM
  # спотыкается. Правило «.ps1 обязаны быть с BOM» касается скриптов,
  # а не данных, которые они пишут.
  [System.IO.File]::WriteAllText($path, $json, [System.Text.UTF8Encoding]::new($false))
  return $path
}

function Format-VersionLine {
  <#
    .SYNOPSIS
      Одна строка о версии — для консоли.
  #>
  param([Parameter(Mandatory)]$Stamp)

  $line = "$($Stamp.commit_short) ($($Stamp.branch))"
  if ($Stamp.dirty) {
    $line += " — DIRTY: незакоммиченных файлов $($Stamp.dirty_files)"
  }
  return $line
}
