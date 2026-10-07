# Тесты функций из scripts/lib-backup.ps1 без сети и без Pester.
# Запуск: pwsh -NoProfile -File tests/lib-backup.tests.ps1   (код выхода 1, если что-то упало)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'scripts' 'lib-backup.ps1')

$script:failures = 0
$script:passed = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if ($Condition) { $script:passed++ }
    else { $script:failures++; Write-Host "FAIL: $Message" -ForegroundColor Red }
}
function Assert-Equal($Actual, $Expected, [string]$Message) {
    Assert-True ($Actual -eq $Expected) "$Message (получено '$Actual', ожидалось '$Expected')"
}
function Assert-Throws([scriptblock]$Block, [string]$Pattern, [string]$Message) {
    $threw = $false
    try { & $Block } catch { $threw = $true; Assert-True ($_.Exception.Message -match $Pattern) "$Message (текст ошибки: $($_.Exception.Message))" }
    if (-not $threw) { Assert-True $false "$Message (исключения не было)" }
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("lib-backup-tests-" + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($tmp)

function Sha([string]$Text) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
}

try {
    # ---------------- Read-Conf
    $confPath = Join-Path $tmp 'p.conf'
    Set-Content -LiteralPath $confPath -Encoding UTF8 -Value @(
        '# комментарий', '', 'A=1', 'LOCAL_REPOS=C:\one;C:\two', 'EMPTY=', 'KEY = spaced value ')
    $c = Read-Conf $confPath
    Assert-Equal $c['A'] '1' 'Read-Conf: простое значение'
    Assert-Equal $c['LOCAL_REPOS'] 'C:\one;C:\two' 'Read-Conf: ; и \ сохраняются'
    Assert-Equal $c['EMPTY'] '' 'Read-Conf: пустое значение'
    Assert-Equal $c['KEY'] 'spaced value' 'Read-Conf: пробелы вокруг ключа и значения срезаются'
    Assert-True (-not $c.ContainsKey('# комментарий')) 'Read-Conf: комментарии пропускаются'

    # ---------------- Write-Utf8NoBom
    $m = Join-Path $tmp 'marker.json'
    Write-Utf8NoBom $m '{"a":1}'
    $b = [System.IO.File]::ReadAllBytes($m)
    Assert-True ($b[0] -eq 0x7B) 'Write-Utf8NoBom: первый байт это {, а не BOM'

    # ---------------- Get-StampDate / Get-StampAgeHours
    $now = [datetime]::SpecifyKind([datetime]'2026-10-07 13:00:00', 'Utc')
    Assert-Equal (Get-StampAgeHours '20261007-000000' $now) 13 'возраст снимка в часах'
    Assert-Equal (Get-StampAgeHours '20261006-130000' $now) 24 'возраст ровно сутки'
    Assert-True ((Get-StampDate '20261007-123000').Hour -eq 12) 'Get-StampDate читает время'

    # ---------------- Read-RemoteListing
    $h1 = ('a' * 64); $h2 = ('B' * 64)
    $ok = Read-RemoteListing -Lines @('DIR=20261007-003000/', "$h1  ./database.dump", "$h2  ./OK")
    Assert-Equal $ok.Stamp '20261007-003000' 'Read-RemoteListing: имя каталога без /'
    Assert-Equal $ok.Files.Count 2 'Read-RemoteListing: два файла'
    Assert-Equal $ok.Files['OK'] ('b' * 64) 'Read-RemoteListing: сумма в нижнем регистре, ./ срезано'

    $noisy = Read-RemoteListing -Lines @(
        'Warning: Permanently added host to the list of known hosts.',
        'DIR=20261007-003000/', "$h1  ./database.dump", "$h2  ./OK")
    Assert-Equal $noisy.Files.Count 2 'Read-RemoteListing: предупреждение ssh не считается файлом'

    Assert-Throws { Read-RemoteListing -Lines @('DIR=20261007-003000/', "$h1  ./database.dump") } 'нет отметки' 'нет OK: отказ'
    Assert-Throws { Read-RemoteListing -Lines @('DIR=20261007-003000/') } 'пуст' 'пустой каталог: отказ'
    Assert-Throws { Read-RemoteListing -Lines @("$h1  ./database.dump", "$h2  ./OK") } 'не назвал' 'нет DIR=: отказ'

    # ---------------- Test-CopyIntact
    $dir = Join-Path $tmp 'snap'
    [void][System.IO.Directory]::CreateDirectory((Join-Path $dir 'sub'))
    Set-Content -LiteralPath (Join-Path $dir 'database.dump') -Value 'dump-content' -NoNewline -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $dir 'OK') -Value 'ok' -NoNewline -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $dir 'sub' 'inner.txt') -Value 'inner' -NoNewline -Encoding ASCII
    $exp = @{
        'database.dump' = Sha 'dump-content'
        'OK'            = Sha 'ok'
        'sub/inner.txt' = Sha 'inner'
    }
    Assert-Equal (@(Test-CopyIntact -Expected $exp -Directory $dir)).Count 0 'Test-CopyIntact: всё сошлось'

    $missing = $exp.Clone(); $missing['absent.txt'] = Sha 'x'
    $r = @(Test-CopyIntact -Expected $missing -Directory $dir)
    Assert-True (($r -join ';') -match 'absent.txt - файла нет') 'Test-CopyIntact: нет файла'

    $wrong = $exp.Clone(); $wrong['OK'] = Sha 'другое'
    $r = @(Test-CopyIntact -Expected $wrong -Directory $dir)
    Assert-True (($r -join ';') -match 'OK - сумма разошлась') 'Test-CopyIntact: другая сумма'

    $short = @{ 'database.dump' = Sha 'dump-content'; 'OK' = Sha 'ok' }
    $r = @(Test-CopyIntact -Expected $short -Directory $dir)
    Assert-True (($r -join ';') -match 'sub/inner.txt - лишний файл') 'Test-CopyIntact: лишний файл во вложенной папке'

    # ---------------- Remove-OldCopies
    $store = Join-Path $tmp 'store'
    [void][System.IO.Directory]::CreateDirectory($store)
    function New-Snap([string]$Name, [bool]$WithCore = $true) {
        $d = Join-Path $store $Name
        [void][System.IO.Directory]::CreateDirectory($d)
        if ($WithCore) { Set-Content -LiteralPath (Join-Path $d 'database.dump') -Value 'x' -Encoding ASCII }
    }
    New-Snap '20260101-000000'   # старый
    New-Snap '20260301-000000'   # старый
    New-Snap '20260601-000000'   # старый
    New-Snap '20261005-000000'   # свежий
    New-Snap '20261006-000000'   # свежий
    New-Snap '20260102-000000' $false   # чужой: похожее имя, но без database.dump
    [void][System.IO.Directory]::CreateDirectory((Join-Path $store 'notes'))   # чужой каталог

    $now2 = [datetime]::SpecifyKind([datetime]'2026-10-07 12:00:00', 'Utc')
    $gone = @(Remove-OldCopies -Store $store -Days 30 -AtLeast 3 -Now $now2)
    Assert-Equal ($gone -join ',') '20260301-000000,20260101-000000' 'Remove-OldCopies: удалены старые сверх пола, свежие и пол сохранены'
    # пол 3: свежие 20261006, 20261005 и 20260601 не трогаем при любом возрасте
    Assert-True (Test-Path -LiteralPath (Join-Path $store '20260601-000000')) 'Remove-OldCopies: третья копия держится полом'
    Assert-True (Test-Path -LiteralPath (Join-Path $store '20260102-000000')) 'Remove-OldCopies: каталог без database.dump не тронут'
    Assert-True (Test-Path -LiteralPath (Join-Path $store 'notes')) 'Remove-OldCopies: чужой каталог не тронут'

    # пол сильнее срока: через два года простоя остаются три копии
    $far = [datetime]::SpecifyKind([datetime]'2028-10-07 12:00:00', 'Utc')
    $gone2 = @(Remove-OldCopies -Store $store -Days 30 -AtLeast 3 -Now $far)
    Assert-Equal $gone2.Count 0 'Remove-OldCopies: при трёх своих копиях удалять нечего даже через два года'
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "прошло: $script:passed, упало: $script:failures"
if ($script:failures -gt 0) { exit 1 }
exit 0
