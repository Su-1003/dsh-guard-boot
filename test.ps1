# test.ps1 - regression suite for dsh-guard-boot.
#
# Every case builds an isolated sandbox under %TEMP%\dsh-guard-test-<stamp>\
#   <case>\crash\   crash-log directory fed to the watchdog
#   <case>\snap\    snapshot root (pre-boot-*, last-good, pre-rollback-*)
#   <case>\logs\    watchdog logs
# Nothing under ~\.dsh is touched.  All runs pass -NoNotice, so no dialogs.
#
# Usage:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File test.ps1
#   ... -File test.ps1 -Keep        keep the sandbox for inspection
#   ... -File test.ps1 -Filter g     run only cases whose name contains "g"
#
# Exit code: 0 = every case passed, 1 = at least one failed.

param(
    [string]$WorkRoot = '',
    [string]$Filter   = '',
    [switch]$Keep
)

$ErrorActionPreference = 'Stop'

$Here     = Split-Path -Parent $MyInvocation.MyCommand.Path
$Watchdog = Join-Path $Here 'watchdog.ps1'
$Ps51     = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$RealProfile = Join-Path $env:USERPROFILE '.dsh\profiles\desktop'

if (-not (Test-Path -LiteralPath $Watchdog)) { throw "watchdog.ps1 not found next to test.ps1: $Watchdog" }
if (-not (Test-Path -LiteralPath $Ps51))     { throw "Windows PowerShell 5.1 not found: $Ps51" }
if (-not (Test-Path -LiteralPath $RealProfile)) { throw "profile not found: $RealProfile" }
if (-not $WorkRoot) { $WorkRoot = Join-Path $env:TEMP ('dsh-guard-test-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
if (Test-Path -LiteralPath $WorkRoot) { Remove-Item -LiteralPath $WorkRoot -Recurse -Force }
New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null

$script:Passed = 0
$script:Failed = 0
$script:Failures = @()

function Assert([string]$name, [bool]$ok, [string]$detail) {
    if ($ok) {
        $script:Passed++
        Write-Host ('  PASS  ' + $name) -ForegroundColor Green
    } else {
        $script:Failed++
        $script:Failures += ($name + '  ' + $detail)
        Write-Host ('  FAIL  ' + $name + '   ' + $detail) -ForegroundColor Red
    }
}

function New-Case([string]$name) {
    $d = Join-Path $WorkRoot $name
    foreach ($sub in 'crash', 'snap', 'logs', 'profile') {
        New-Item -ItemType Directory -Path (Join-Path $d $sub) -Force | Out-Null
    }
    # 每个用例自带一份 profile 副本：回滚要往 profile 里写文件，
    # 用真实 profile 会污染 ~\.dsh（受限环境里也直接 Access denied）。
    foreach ($f in 'package.json', 'pnpm-lock.yaml', 'pnpm-workspace.yaml', 'cordis.yml', 'cordis.patch.yml', 'compatibility.json') {
        $src = Join-Path $RealProfile $f
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination (Join-Path $d ('profile\' + $f)) -Force
        }
    }
    return $d
}

function Write-CrashLog([string]$CrashDir, [string]$fileName, [int]$ageDays, [string[]]$lines) {
    $f = Join-Path $CrashDir $fileName
    Set-Content -LiteralPath $f -Value $lines -Encoding UTF8
    $stamp = (Get-Date).AddDays(-$ageDays)
    if ($ageDays -gt 0) { $stamp = $stamp.AddMinutes(-1) }   # 0 天 = 就是现在
    (Get-Item -LiteralPath $f).LastWriteTime = $stamp
    return $f
}

function New-FreshProcess([string]$title) {
    return Start-Process -FilePath 'cmd.exe' -ArgumentList '/k', ('title ' + $title) -PassThru
}

function Stop-FreshProcess($proc) {
    if ($proc -and -not $proc.HasExited) { try { $proc.Kill() } catch {} }
}

function Invoke-Watchdog {
    param(
        [string]$Dir,
        [hashtable]$Extra = @{},
        [string]$ProcessName = 'cmd',
        [string]$ProfileDir = ''
    )
    if (-not $ProfileDir) { $ProfileDir = Join-Path $Dir 'profile' }
    $a = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Watchdog,
        '-ProfileName', 'desktop', '-ProfileDir', $ProfileDir,
        '-SnapshotRoot', (Join-Path $Dir 'snap'),
        '-CrashLogDir',  (Join-Path $Dir 'crash'),
        '-LogDir',       (Join-Path $Dir 'logs'),
        '-ProcessName',  $ProcessName,
        '-WaitSeconds', '1', '-StartupWatchSeconds', '10',
        '-KeepProcesses', '-NoRelaunch', '-NoNotice'
    )
    foreach ($k in $Extra.Keys) {
        $a += ('-' + $k)
        if ($Extra[$k] -ne $true) { $a += [string]$Extra[$k] }
    }
    # 用调用运算符而不是 Start-Process：-NoNewWindow 在受限环境会 Access is denied，
    # 且 -ArgumentList 拼接时不加引号，带空格的路径会被截断。
    & $Ps51 @a 2>$null | Out-Null
    return $LASTEXITCODE
}

function Get-WatchdogLog([string]$Dir) {
    $f = Get-ChildItem -LiteralPath (Join-Path $Dir 'logs') -Filter 'watchdog-*.log' -ErrorAction SilentlyContinue |
         Sort-Object LastWriteTime | Select-Object -Last 1
    if (-not $f) { return '' }
    return (Get-Content -LiteralPath $f.FullName -ErrorAction SilentlyContinue) -join "`n"
}

function Count-Dirs([string]$Dir, [string]$Pattern) {
    return @(Get-ChildItem -LiteralPath $Dir -Directory -Filter $Pattern -ErrorAction SilentlyContinue).Count
}

$cases = [ordered]@{

    'a-healthy' = {
        $d = New-Case 'a-healthy'
        $proc = New-FreshProcess 'testA'
        Start-Sleep -Seconds 2
        $code = Invoke-Watchdog -Dir $d
        $log = Get-WatchdogLog $d
        Assert 'a exit 0' ($code -eq 0) ('exit=' + $code)
        Assert 'a certified last-good' ($log -match 'OK: refreshed last-good') ''
        Assert 'a last-good exists' (Test-Path -LiteralPath (Join-Path $d 'snap\last-good')) ''
        Stop-FreshProcess $proc
    }

    'b-no-window' = {
        $d = New-Case 'b-no-window'
        $proc = New-FreshProcess 'testB'
        Start-Sleep -Seconds 2
        $code = Invoke-Watchdog -Dir $d -Extra @{ SimulateNoWindow = $true }
        $log = Get-WatchdogLog $d
        Assert 'b exit 0' ($code -eq 0) ('exit=' + $code)
        Assert 'b skipped certifying' ($log -match 'SKIP: window never appeared') ''
        Assert 'b last-good absent' (-not (Test-Path -LiteralPath (Join-Path $d 'snap\last-good'))) ''
        Stop-FreshProcess $proc
    }

    'c-crash' = {
        $d = New-Case 'c-crash'
        $proc = New-FreshProcess 'testC'
        Start-Sleep -Seconds 2
        $code = Invoke-Watchdog -Dir $d -Extra @{ SimulateCrash = $true }
        $log = Get-WatchdogLog $d
        Assert 'c exit 1' ($code -eq 1) ('exit=' + $code)
        Assert 'c restored 6 files' ($log -match 'restored 6 config file') ''
        Assert 'c pre-rollback saved' ((Count-Dirs (Join-Path $d 'snap') 'pre-rollback-*') -ge 1) ''
        Stop-FreshProcess $proc
    }

    'd-authfail' = {
        $d = New-Case 'd-authfail'
        $proc = New-FreshProcess 'testD'
        Start-Sleep -Seconds 2
        $code = Invoke-Watchdog -Dir $d -Extra @{ SimulateAuthFail = $true }
        $log = Get-WatchdogLog $d
        Assert 'd exit 2' ($code -eq 2) ('exit=' + $code)
        Assert 'd reported AUTH-FAIL' ($log -match 'AUTH-FAIL') ''
        Assert 'd did not roll back' ((Count-Dirs (Join-Path $d 'snap') 'pre-rollback-*') -eq 0) ''
        Stop-FreshProcess $proc
    }

    'e-no-profile' = {
        $d = New-Case 'e-no-profile'
        $empty = Join-Path $WorkRoot 'e-empty-profile'
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        $proc = New-FreshProcess 'testE'
        Start-Sleep -Seconds 2
        $code = Invoke-Watchdog -Dir $d -ProfileDir $empty
        $log = Get-WatchdogLog $d
        Assert 'e exit 0 (fail-open)' ($code -eq 0) ('exit=' + $code)
        Assert 'e aborted' ($log -match 'ABORT') ''
        Stop-FreshProcess $proc
    }

    'f-prune' = {
        $d = New-Case 'f-prune'
        for ($i = 1; $i -le 8; $i++) {
            $p = Join-Path $d ('snap\pre-boot-2026010' + $i + '-000000')
            New-Item -ItemType Directory -Path $p -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $p 'package.json') -Value '{}' -Encoding UTF8
        }
        for ($i = 1; $i -le 12; $i++) {
            $p = Join-Path $d ('snap\pre-rollback-2026010' + $i + '-000000')
            New-Item -ItemType Directory -Path $p -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $p 'package.json') -Value '{}' -Encoding UTF8
        }
        $proc = New-FreshProcess 'testF'
        Start-Sleep -Seconds 2
        $null = Invoke-Watchdog -Dir $d
        Assert 'f pre-boot pruned to 5'  ((Count-Dirs (Join-Path $d 'snap') 'pre-boot-*') -eq 5)  ('got ' + (Count-Dirs (Join-Path $d 'snap') 'pre-boot-*'))
        Assert 'f pre-rollback pruned to 10' ((Count-Dirs (Join-Path $d 'snap') 'pre-rollback-*') -eq 10) ('got ' + (Count-Dirs (Join-Path $d 'snap') 'pre-rollback-*'))
        Stop-FreshProcess $proc
    }

    'g-old-logs-healthy' = {
        $d = New-Case 'g-old-logs-healthy'
        for ($i = 1; $i -le 3; $i++) {
            $null = Write-CrashLog (Join-Path $d 'crash') ('crash-2026-10-20T10-0' + $i + '-00-000Z-web-boot.log') 2 @('old crash ' + $i)
        }
        $proc = New-FreshProcess 'testG'
        Start-Sleep -Seconds 2
        $code = Invoke-Watchdog -Dir $d
        $log = Get-WatchdogLog $d
        Assert 'g exit 0' ($code -eq 0) ('exit=' + $code)
        Assert 'g ignored old crash logs' ($log -match 'new-crash-logs=0') ''
        Assert 'g certified last-good' (Test-Path -LiteralPath (Join-Path $d 'snap\last-good')) ''
        Stop-FreshProcess $proc
    }

    'h-old-plus-new' = {
        $d = New-Case 'h-old-plus-new'
        for ($i = 1; $i -le 3; $i++) {
            $null = Write-CrashLog (Join-Path $d 'crash') ('crash-2026-10-20T10-0' + $i + '-00-000Z-web-boot.log') 2 @('old crash ' + $i)
        }
        $proc = New-FreshProcess 'testH'
        Start-Sleep -Seconds 2
        $null = Write-CrashLog (Join-Path $d 'crash') 'crash-2026-10-26T00-50-00-000Z-web-boot.log' 0 @('Error: web boot: 1 entry did not activate')
        $code = Invoke-Watchdog -Dir $d
        $log = Get-WatchdogLog $d
        Assert 'h exit 1' ($code -eq 1) ('exit=' + $code)
        Assert 'h detected 1 new log' ($log -match 'new-crash-logs=1') ''
        Stop-FreshProcess $proc
    }

    'i-same-name-rewritten' = {
        $d = New-Case 'i-same-name-rewritten'
        $name = 'crash-2026-10-26T00-45-00-000Z-web-boot.log'
        $null = Write-CrashLog (Join-Path $d 'crash') $name 1 @('old crash')
        $proc = New-FreshProcess 'testI'
        Start-Sleep -Seconds 2
        $null = Write-CrashLog (Join-Path $d 'crash') $name 0 @('Error: desktop welcome: Web authentication failed')
        $code = Invoke-Watchdog -Dir $d
        $log = Get-WatchdogLog $d
        Assert 'i exit 2' ($code -eq 2) ('exit=' + $code)
        Assert 'i caught the rewrite' ($log -match 'new-crash-logs=1') ''
        Assert 'i reported AUTH-FAIL' ($log -match 'AUTH-FAIL') ''
        Stop-FreshProcess $proc
    }

    'l1-lock-held' = {
        $d = New-Case 'l1-lock-held'
        $holder = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 30' -PassThru
        Start-Sleep -Seconds 2
        Set-Content -LiteralPath (Join-Path $d 'snap\watchdog.lock') -Value ('pid=' + $holder.Id) -Encoding ASCII
        $proc = New-FreshProcess 'testL1'
        Start-Sleep -Seconds 2
        $code = Invoke-Watchdog -Dir $d
        $log = Get-WatchdogLog $d
        Assert 'l1 exit 0' ($code -eq 0) ('exit=' + $code)
        Assert 'l1 saw the other watchdog' ($log -match 'another watchdog') ''
        Assert 'l1 did not snapshot' (-not (Test-Path -Path (Join-Path $d 'snap\pre-boot-*'))) ''
        Assert 'l1 left the foreign lock alone' ((Get-Content -LiteralPath (Join-Path $d 'snap\watchdog.lock') -Raw) -match ('pid=' + $holder.Id)) ''
        Stop-FreshProcess $proc
        Stop-FreshProcess $holder
    }

    'l2-lock-stale' = {
        $d = New-Case 'l2-lock-stale'
        Set-Content -LiteralPath (Join-Path $d 'snap\watchdog.lock') -Value 'pid=999999' -Encoding ASCII
        $proc = New-FreshProcess 'testL2'
        Start-Sleep -Seconds 2
        $code = Invoke-Watchdog -Dir $d
        $log = Get-WatchdogLog $d
        Assert 'l2 exit 0' ($code -eq 0) ('exit=' + $code)
        Assert 'l2 took over stale lock' ($log -match 'lock\s+:') ''
        Assert 'l2 released the lock' (-not (Test-Path -LiteralPath (Join-Path $d 'snap\watchdog.lock'))) ''
        Stop-FreshProcess $proc
    }

    'n1-hang-first' = {
        $d = New-Case 'n1-hang-first'
        # 先放一份「崩溃连续失败」计数，用来验证卡死不会把它清掉
        Set-Content -LiteralPath (Join-Path $d 'snap\fail-streak.json') -Value '{"fingerprint":"x","streak":1}' -Encoding UTF8
        $proc = New-FreshProcess 'testN1'
        Start-Sleep -Seconds 2
        $code = Invoke-Watchdog -Dir $d -Extra @{ SimulateNoWindow = $true }
        $log = Get-WatchdogLog $d
        Assert 'n1 exit 0' ($code -eq 0) ('exit=' + $code)
        Assert 'n1 counted the hang' ($log -match 'HANG: no window again \(streak 1\)') ''
        Assert 'n1 hang streak file written' (Test-Path -LiteralPath (Join-Path $d 'snap\hang-streak.json')) ''
        Assert 'n1 kept fail-streak' (Test-Path -LiteralPath (Join-Path $d 'snap\fail-streak.json')) ''
        Stop-FreshProcess $proc
    }

    'n2-hang-twice' = {
        $d = New-Case 'n2-hang-twice'
        Set-Content -LiteralPath (Join-Path $d 'snap\hang-streak.json') -Value '{"count":1,"at":"2026-10-26T00:00:00"}' -Encoding UTF8
        $proc = New-FreshProcess 'testN2'
        Start-Sleep -Seconds 2
        $code = Invoke-Watchdog -Dir $d -Extra @{ SimulateNoWindow = $true }
        $log = Get-WatchdogLog $d
        Assert 'n2 exit 0' ($code -eq 0) ('exit=' + $code)
        Assert 'n2 reached streak 2' ($log -match 'HANG: no window again \(streak 2\)') ''
        Assert 'n2 still did not certify' (-not (Test-Path -LiteralPath (Join-Path $d 'snap\last-good'))) ''
        Stop-FreshProcess $proc
    }

    'n3-hang-cleared-by-healthy' = {
        $d = New-Case 'n3-hang-cleared-by-healthy'
        Set-Content -LiteralPath (Join-Path $d 'snap\hang-streak.json') -Value '{"count":3,"at":"2026-10-26T00:00:00"}' -Encoding UTF8
        $proc = New-FreshProcess 'testN3'
        Start-Sleep -Seconds 2
        $code = Invoke-Watchdog -Dir $d
        $log = Get-WatchdogLog $d
        Assert 'n3 exit 0' ($code -eq 0) ('exit=' + $code)
        Assert 'n3 certified' ($log -match 'OK: refreshed last-good') ''
        Assert 'n3 cleared hang streak' (-not (Test-Path -LiteralPath (Join-Path $d 'snap\hang-streak.json'))) ''
        Stop-FreshProcess $proc
    }
}

Write-Host ''
Write-Host ('dsh-guard-boot regression suite   sandbox: ' + $WorkRoot) -ForegroundColor Cyan
Write-Host ''

foreach ($name in $cases.Keys) {
    if ($Filter -and ($name -notlike ('*' + $Filter + '*'))) { continue }
    Write-Host ('case ' + $name) -ForegroundColor White
    & $cases[$name]
}

Write-Host ''
Write-Host ('passed: ' + $script:Passed + '   failed: ' + $script:Failed) -ForegroundColor Cyan
if ($script:Failed -gt 0) {
    Write-Host 'failures:' -ForegroundColor Red
    foreach ($f in $script:Failures) { Write-Host ('  - ' + $f) -ForegroundColor Red }
}

if ($Keep) {
    Write-Host ('sandbox kept: ' + $WorkRoot) -ForegroundColor Yellow
} else {
    Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Failed -gt 0) { exit 1 }
exit 0
