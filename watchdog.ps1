# watchdog.ps1 — DSH 旁路守护：启动后查一次崩溃日志，坏了就回滚配置并重启
#
# 设计要点（换来的是「启动零等待」）：
#   1. 它不在启动路径上：exe 由 start-dsh.vbs 先拉起，本脚本只做快照与事后检查。
#   2. 只看崩溃日志（名字不在基线里 / 修改时间晚于启动）——进程存活不可靠，
#      web boot 失败时进程是活着的。
#   3. 失败即放弃（fail-open）：本脚本任何异常都不影响已启动的 App，只写日志。
#
# 正常使用不需要手动调用它 —— start-dsh.vbs 会拉起它。安装请跑 install.ps1。

param(
    [string]$ExePath      = '',
    [string]$ProcessName  = 'DeepSeek Harness',
    [string]$ProfileName  = '',
    [string]$ProfileDir   = '',
    [string]$SnapshotRoot = '',
    [string]$CrashLogDir  = '',
    [int]$WaitSeconds     = -1,
    [switch]$SimulateCrash,
    [switch]$NoRelaunch,
    [switch]$KeepProcesses,
    [switch]$NoNotice,
    [string]$LogDir       = ''
)

$ErrorActionPreference = 'Continue'
$SnapFiles = @('package.json','pnpm-lock.yaml','pnpm-workspace.yaml','cordis.yml','cordis.patch.yml','compatibility.json')
$KeepSnapshots = 5

# ---------- 配置来源：命令行 > config.ini > 自动发现 ----------
$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptDir)) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$ConfigFile = Join-Path $ScriptDir 'config.ini'

function Read-Ini {
    param([string]$path)
    $h = @{}
    if (-not (Test-Path $path)) { return $h }
    foreach ($line in (Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith(';') -or $t.StartsWith('#')) { continue }
        $i = $t.IndexOf('=')
        if ($i -gt 0) { $h[$t.Substring(0, $i).Trim()] = $t.Substring($i + 1).Trim() }
    }
    return $h
}

function Find-DshExe {
    $cands = New-Object System.Collections.ArrayList

    # 1) 卸载表里的 InstallLocation / DisplayIcon
    $roots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($r in $roots) {
        if (-not (Test-Path $r)) { continue }
        Get-ChildItem $r -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($p -and $p.DisplayName -like '*DeepSeek Harness*') {
                if ($p.InstallLocation) { [void]$cands.Add((Join-Path $p.InstallLocation 'DeepSeek Harness.exe')) }
                if ($p.DisplayIcon) {
                    $icon = ($p.DisplayIcon -split ',')[0].Trim('"')
                    if ($icon -like '*.exe') { [void]$cands.Add($icon) }
                }
            }
        }
    }

    # 2) 已有快捷方式指向的 exe（桌面 / 公共桌面 / 开始菜单）
    $lnkDirs = @(
        [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('CommonDesktopDirectory'),
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs')
    )
    $wsh = $null
    try { $wsh = New-Object -ComObject WScript.Shell } catch {}
    if ($wsh) {
        foreach ($d in $lnkDirs) {
            if (-not $d -or -not (Test-Path $d)) { continue }
            Get-ChildItem $d -Filter '*.lnk' -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like '*DeepSeek*' } | ForEach-Object {
                    try {
                        $t = $wsh.CreateShortcut($_.FullName).TargetPath
                        if ($t -like '*DeepSeek Harness.exe') { [void]$cands.Add($t) }
                    } catch {}
                }
        }
    }

    # 3) 常见安装位置
    $rel = 'DeepSeek Harness\DeepSeek Harness.exe'
    [void]$cands.Add((Join-Path $env:LOCALAPPDATA ('Programs\' + $rel)))
    [void]$cands.Add((Join-Path $env:ProgramFiles $rel))
    [void]$cands.Add((Join-Path ${env:ProgramFiles(x86)} $rel))

    foreach ($c in $cands) {
        if ($c -and (Test-Path -LiteralPath $c)) { return (Resolve-Path -LiteralPath $c).Path }
    }
    return $null
}

$cfg = Read-Ini $ConfigFile

if ([string]::IsNullOrWhiteSpace($ExePath))      { $ExePath = $cfg['ExePath'] }
if ([string]::IsNullOrWhiteSpace($ProfileName))  { $ProfileName = $cfg['ProfileName'] }
if ([string]::IsNullOrWhiteSpace($ProfileName))  { $ProfileName = 'desktop' }
if ([string]::IsNullOrWhiteSpace($ProfileDir))   { $ProfileDir = Join-Path $env:USERPROFILE ('.dsh\profiles\' + $ProfileName) }
if ([string]::IsNullOrWhiteSpace($SnapshotRoot)) { $SnapshotRoot = Join-Path $env:USERPROFILE '.dsh\boot-snapshots' }
if ([string]::IsNullOrWhiteSpace($CrashLogDir))  { $CrashLogDir = Join-Path $env:APPDATA '@deepseek-ai\dsh-desktop\logs' }
if ($WaitSeconds -lt 0) {
    $WaitSeconds = 20
    if ($cfg['WaitSeconds'] -and ($cfg['WaitSeconds'] -match '^\d+$')) { $WaitSeconds = [int]$cfg['WaitSeconds'] }
}
if ([string]::IsNullOrWhiteSpace($LogDir))       { $LogDir = Join-Path $ScriptDir 'logs' }
if ([string]::IsNullOrWhiteSpace($ExePath))      { $ExePath = Find-DshExe }
if ([string]::IsNullOrWhiteSpace($ExePath))      { $ExePath = '' }

$logFile = $null
function Write-Log {
    param([string]$msg)
    $line = '[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $msg
    Write-Host $line
    if ($logFile) { try { Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8 } catch {} }
}

function Copy-ConfigSnapshot {
    param([string]$src, [string]$dst)
    if (-not (Test-Path $dst)) { New-Item -ItemType Directory -Force -Path $dst | Out-Null }
    foreach ($f in $SnapFiles) {
        $s = Join-Path $src $f
        if (Test-Path $s) { Copy-Item -LiteralPath $s -Destination (Join-Path $dst $f) -Force }
    }
}

function Restore-ConfigSnapshot {
    param([string]$src, [string]$dst)
    $n = 0
    foreach ($f in $SnapFiles) {
        $s = Join-Path $src $f
        if (Test-Path $s) {
            Copy-Item -LiteralPath $s -Destination (Join-Path $dst $f) -Force
            $n++
        }
    }
    return $n
}

function Show-Notice {
    param([string]$text, [int]$icon)
    try {
        $w = New-Object -ComObject WScript.Shell
        [void]$w.Popup($text, 25, 'DSH guard boot', $icon)
    } catch {}
}

try {
    $started = Get-Date
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
    $logFile = Join-Path $LogDir ('watchdog-' + $started.ToString('yyyyMMdd-HHmmss') + '.log')
    Write-Log '=== watchdog start ==='
    Write-Log ('profile : ' + $ProfileDir)
    Write-Log ('exe     : ' + $ExePath)

    # ---- 1. 基线：启动时刻已存在的崩溃日志 ----
    $baseline = @{}
    if (Test-Path $CrashLogDir) {
        Get-ChildItem -LiteralPath $CrashLogDir -Filter 'crash-*.log' -File -ErrorAction SilentlyContinue |
            ForEach-Object { $baseline[$_.Name] = $true }
    }
    Write-Log ('baseline crash logs: ' + $baseline.Count)

    # ---- 2. 启动后快照（pre-boot）----
    $preDir = Join-Path $SnapshotRoot ('pre-boot-' + $started.ToString('yyyyMMdd-HHmmss'))
    Copy-ConfigSnapshot -src $ProfileDir -dst $preDir
    $snapCount = @(Get-ChildItem -LiteralPath $preDir -File -ErrorAction SilentlyContinue).Count
    Write-Log ('snapshot: ' + $preDir + ' -> ' + $snapCount + ' files')

    # 快照不完整 = profile 路径不对或文件读不到：直接放弃，绝不拿空快照去覆盖 last-good
    if (-not (Test-Path $ProfileDir) -or $snapCount -lt 3) {
        Write-Log 'ABORT: profile missing or snapshot incomplete (fail-open, nothing changed)'
        exit 0
    }

    # ---- 3. 等窗口稳定，期间不阻塞任何东西 ----
    if ($WaitSeconds -gt 0) { Start-Sleep -Seconds $WaitSeconds }

    if ($SimulateCrash) {
        if (-not (Test-Path $CrashLogDir)) { New-Item -ItemType Directory -Force -Path $CrashLogDir | Out-Null }
        $fake = Join-Path $CrashLogDir ('crash-' + (Get-Date -Format 'yyyy-MM-ddTHH-mm-ss-fffZ') + '-web-boot.log')
        Set-Content -LiteralPath $fake -Value 'SIMULATED: web boot: 1 entry did not activate' -Encoding UTF8
        Write-Log ('SimulateCrash: wrote ' + $fake)
    }

    # ---- 4. 判定 ----
    $newLogs = @()
    if (Test-Path $CrashLogDir) {
        $newLogs = @(Get-ChildItem -LiteralPath $CrashLogDir -Filter 'crash-*.log' -File -ErrorAction SilentlyContinue |
            Where-Object { (-not $baseline.ContainsKey($_.Name)) -or ($_.LastWriteTime -gt $started) })
    }
    $procAlive = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue).Count
    Write-Log ('check: new-crash-logs=' + $newLogs.Count + '  running-processes=' + $procAlive)

    if ($newLogs.Count -eq 0) {
        # ---- 健康：把这份快照提升为 last-good ----
        # 但进程数为 0 时拒绝认证：App 没在跑，这份配置没有被"跑通"验证过，
        # 若它其实是坏的，认证成 last-good 会让下次回滚也退到坏配置。
        $goodDir = Join-Path $SnapshotRoot 'last-good'
        if ($procAlive -gt 0) {
            if (Test-Path $goodDir) { Remove-Item -LiteralPath $goodDir -Recurse -Force -ErrorAction SilentlyContinue }
            Copy-ConfigSnapshot -src $preDir -dst $goodDir
            Write-Log ('OK: refreshed last-good -> ' + $goodDir)

            # 修剪旧 pre-boot（只留最近 $KeepSnapshots 份）
            $olds = @(Get-ChildItem -LiteralPath $SnapshotRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like 'pre-boot-*' } | Sort-Object Name -Descending | Select-Object -Skip $KeepSnapshots)
            foreach ($o in $olds) {
                Remove-Item -LiteralPath $o.FullName -Recurse -Force -ErrorAction SilentlyContinue
                Write-Log ('pruned: ' + $o.Name)
            }
        } else {
            Write-Log ('SKIP: no running process named "' + $ProcessName + '" - not certifying this config as last-good')
        }
        Write-Log '=== watchdog end (healthy) ==='
        exit 0
    }

    # ---- 5. 失败：回滚 ----
    Write-Log ('FAIL: ' + (($newLogs | ForEach-Object { $_.Name }) -join ', '))
    foreach ($l in $newLogs) {
        $head = Get-Content -LiteralPath $l.FullName -TotalCount 6 -ErrorAction SilentlyContinue
        Write-Log ('  ' + $l.Name + ' :: ' + (($head -join ' | ') -replace '\s+', ' '))
    }

    $goodDir = Join-Path $SnapshotRoot 'last-good'
    if (Test-Path $goodDir) {
        $restoreFrom = $goodDir
        Write-Log ('rollback source: ' + $goodDir)
    } else {
        $restoreFrom = $preDir
        Write-Log "WARN: no last-good, falling back to this run's pre-boot snapshot"
    }

    if (-not $KeepProcesses) {
        $procs = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
        if ($procs.Count -gt 0) {
            Write-Log ('killing ' + $procs.Count + ' process(es)')
            $procs | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
    }

    $n = Restore-ConfigSnapshot -src $restoreFrom -dst $ProfileDir
    Write-Log ('restored ' + $n + ' config file(s) from ' + $restoreFrom)

    if (-not $NoRelaunch) {
        if ($ExePath -and (Test-Path $ExePath)) {
            Start-Process -FilePath $ExePath | Out-Null
            Write-Log 'relaunched'
        } else {
            Write-Log ('ERROR: exe not found: ' + $ExePath)
        }
    }

    if (-not $NoNotice) {
        Show-Notice ("DSH failed to start. Config rolled back and relaunched.`n`nCrash log: " + ($newLogs[0].Name) + "`nRestored from: " + $restoreFrom + "`n`nDetails: " + $logFile) 48
    }
    Write-Log '=== watchdog end (rolled back) ==='
    exit 1
}
catch {
    # fail-open：守护自己出错，绝不牵连已经启动的 App
    Write-Log ('EXCEPTION: ' + $_.Exception.Message)
    Write-Log ('  at ' + $_.InvocationInfo.ScriptName + ':' + $_.InvocationInfo.ScriptLineNumber)
    exit 0
}
