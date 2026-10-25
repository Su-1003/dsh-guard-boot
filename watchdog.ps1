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
    [int]$StartupWatchSeconds = 120,
    [switch]$SimulateCrash,
    [switch]$SimulateAuthFail,
    [switch]$SimulateNoWindow,
    [int]$StopAfterStreak = 2,
    [switch]$NoRelaunch,
    [switch]$KeepProcesses,
    [switch]$NoNotice,
    [string]$LogDir       = ''
)

$ErrorActionPreference = 'Continue'
$SnapFiles = @('package.json','pnpm-lock.yaml','pnpm-workspace.yaml','cordis.yml','cordis.patch.yml','compatibility.json')
$KeepSnapshots = 5
# 回滚留档（pre-rollback-*）比启动快照值钱，但也不能无限涨
$KeepPreRollback = 10
# 看门狗日志每次启动一个文件，留 90 天足够回溯
$LogKeepDays = 90
# 判定「本次启动是否真的跑起来」的时间容差：exe 由 vbs 先拉起，看门狗晚几百毫秒
$GraceSeconds = 15

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
# 「同一个崩溃指纹连续失败」的计数文件：健康启动会删掉它
$StateFile = Join-Path $SnapshotRoot 'fail-streak.json'
# 「有进程、没窗口」的计数文件：和崩溃计数分开，免得两种故障互相洗掉对方的计数
$HangFile = Join-Path $SnapshotRoot 'hang-streak.json'
# 互斥锁：双击两次图标时只允许一个看门狗真正干活
$LockFile = Join-Path $SnapshotRoot 'watchdog.lock'
if ([string]::IsNullOrWhiteSpace($ExePath))      { $ExePath = '' }

$logFile = $null
function Write-Log {
    param([string]$msg)
    $line = '[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $msg
    Write-Host $line
    if ($logFile) { try { Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8 } catch {} }
}

# 另一个看门狗还活着就返回它的 pid，否则返回 0。
# 判「活着」看两件事：进程在，而且确实是 PowerShell（防止 pid 被别的程序复用）。
function Get-OtherWatchdog {
    if (-not (Test-Path -LiteralPath $LockFile)) { return 0 }
    $raw = Get-Content -LiteralPath $LockFile -Raw -ErrorAction SilentlyContinue
    if ($raw -notmatch 'pid=(\d+)') { return 0 }
    $otherPid = [int]$Matches[1]
    if ($otherPid -le 0 -or $otherPid -eq $PID) { return 0 }
    $p = Get-Process -Id $otherPid -ErrorAction SilentlyContinue
    if (-not $p) { return 0 }
    if ($p.ProcessName -notmatch '^(powershell|pwsh)$') { return 0 }
    return $otherPid
}

function Release-Lock {
    try {
        if (-not (Test-Path -LiteralPath $LockFile)) { return }
        $raw = Get-Content -LiteralPath $LockFile -Raw -ErrorAction SilentlyContinue
        # 只删自己那把锁：别人的锁碰不得
        if ($raw -match ('pid=' + $PID + '\s*$')) {
            Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
        }
    } catch {}
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

function Prune-OldDirs {
    param([string]$Pattern, [int]$Keep)
    $olds = @(Get-ChildItem -LiteralPath $SnapshotRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like $Pattern } | Sort-Object Name -Descending | Select-Object -Skip $Keep)
    foreach ($o in $olds) {
        Remove-Item -LiteralPath $o.FullName -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log ('pruned: ' + $o.Name)
    }
}

function Prune-OldLogs {
    if (-not (Test-Path -LiteralPath $LogDir)) { return }
    $cutoff = (Get-Date).AddDays(-$LogKeepDays)
    $olds = @(Get-ChildItem -LiteralPath $LogDir -Filter 'watchdog-*.log' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff })
    foreach ($o in $olds) {
        Remove-Item -LiteralPath $o.FullName -Force -ErrorAction SilentlyContinue
        Write-Log ('pruned log: ' + $o.Name)
    }
}

function Prune-OldSnapshots {
    Prune-OldDirs -Pattern 'pre-boot-*' -Keep $KeepSnapshots
    # 每次回滚都会留一份 pre-rollback-*：不修剪的话回滚次数多了会一直涨
    Prune-OldDirs -Pattern 'pre-rollback-*' -Keep $KeepPreRollback
    Prune-OldLogs
}

function Get-StartupSeconds {
    # 从「启动时刻」到「窗口真正出现」的秒数。
    # 只认本次启动的新实例：旧实例的窗口一直开着，拿它计时会得到 0 秒的假数据。
    param([datetime]$LaunchAt, [datetime]$FreshAt, [int]$MaxSeconds = 120)
    $deadline = (Get-Date).AddSeconds($MaxSeconds)
    while ((Get-Date) -lt $deadline) {
        foreach ($p in @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)) {
            $fresh = $true
            try { $fresh = ($p.StartTime -ge $FreshAt) } catch { $fresh = $true }
            if (-not $fresh) { continue }
            try {
                if ($p.MainWindowHandle -ne 0) {
                    return [int]([math]::Round(((Get-Date) - $LaunchAt).TotalSeconds))
                }
            } catch { }
        }
        Start-Sleep -Milliseconds 500
    }
    return -1
}

function Show-Notice {
    param([string]$text, [int]$icon, [int]$Seconds = 60)
    try {
        # 先把要说的写进日志：弹窗可能没人看见，日志一定会留下
        Write-Log ('notice: ' + (($text -split "`r`n")[0]) + ' (seconds=' + $Seconds + ')')
        $w = New-Object -ComObject WScript.Shell
        [void]$w.Popup($text, $Seconds, 'DSH guard boot', $icon)
    } catch {}
}

try {
    $started = Get-Date
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
    $logFile = Join-Path $LogDir ('watchdog-' + $started.ToString('yyyyMMdd-HHmmss') + '.log')
    Write-Log '=== watchdog start ==='
    Write-Log ('profile : ' + $ProfileDir)
    Write-Log ('exe     : ' + $ExePath)

    # ---- 0. 互斥：双击两次图标只让一个看门狗干活 ----
    $other = Get-OtherWatchdog
    if ($other -gt 0) {
        Write-Log ('SKIP: another watchdog (pid ' + $other + ') is running')
        Write-Log '=== watchdog end (skipped: another watchdog runs) ==='
        exit 0
    }
    Set-Content -LiteralPath $LockFile -Value ('pid=' + $PID) -Encoding ASCII
    Write-Log ('lock    : ' + $LockFile + ' (pid ' + $PID + ')')

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

    # 复刻真实认证失败日志的形状：20 行、Error 在第 12 行（守护旧版只看前 6 行，正好看不见）
    if ($SimulateAuthFail) {
        if (-not (Test-Path $CrashLogDir)) { New-Item -ItemType Directory -Force -Path $CrashLogDir | Out-Null }
        $fake2 = Join-Path $CrashLogDir ('crash-' + (Get-Date -Format 'yyyy-MM-ddTHH-mm-ss-fffZ') + '-host.log')
        $fakeBody = @(
            'app          : @deepseek-ai/dsh-desktop 0.2.1-rc.3',
            'electron     : 44.7.0',
            'node         : 24.21.0',
            'platform     : win32 x64',
            'locale       : zh-CN',
            'profile      : desktop',
            'profileDir   : C:\Users\WYingJie\.dsh\profiles\desktop',
            'webServer    : 127.0.0.1 (ephemeral)',
            'boot         : 1 entry pending',
            '',
            'stack:',
            'Error: desktop welcome: Web authentication failed',
            '    at welcome (app/main.js:3312:19)',
            '    at process.processTicksAndRejections (node:internal/process/task_queues:95:5)',
            '    at async App.whenReady (app/main.js:2077:5)',
            '',
            'web boot: 1 entry did not activate',
            'diagnostics: see logs above',
            'exit code: 1'
        )
        Set-Content -LiteralPath $fake2 -Value $fakeBody -Encoding UTF8
        Write-Log ('SimulateAuthFail: wrote ' + $fake2)
    }

    # ---- 4. 判定 ----
    # 崩溃日志的容差必须在下面的过滤里就用上：exe 比看门狗先起几百毫秒，
    # 日志时间戳可能早于 $started，只比 $started 会把「刚起就崩」的那一份漏掉。
    # 这个赋值原先写在过滤之后，$crashSince 在过滤时还是 $null；
    # 而 [datetime] -gt $null 恒为 True，会让每一份历史崩溃日志都算「新的」。
    $crashSince = $started.AddSeconds(-$GraceSeconds)
    $newLogs = @()
    if (Test-Path $CrashLogDir) {
        $newLogs = @(Get-ChildItem -LiteralPath $CrashLogDir -Filter 'crash-*.log' -File -ErrorAction SilentlyContinue |
            Where-Object { (-not $baseline.ContainsKey($_.Name)) -or ($_.LastWriteTime -gt $crashSince) })
    }
    # 只认「本次启动」新出现的进程：重复双击图标时那个一直在跑的旧实例不算数，
    # 否则一份根本没启动过的配置会被认证成 last-good。按开始时间判定，
    # 避开 start-dsh.vbs「先起 exe、再起看门狗」的先后抢跑。
    $freshAt = $started.AddSeconds(-$GraceSeconds)
    $procAlive = 0
    foreach ($p in @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)) {
        try { if ($p.StartTime -ge $freshAt) { $procAlive++ } } catch { $procAlive++ }
    }
    Write-Log ('check: new-crash-logs=' + $newLogs.Count + '  fresh-processes=' + $procAlive + ' (started within ' + $GraceSeconds + 's of launch)')

    if ($newLogs.Count -eq 0) {
        # ---- 健康：把这份快照提升为 last-good ----
        # 但进程数为 0 时拒绝认证：App 没在跑，这份配置没有被"跑通"验证过，
        # 若它其实是坏的，认证成 last-good 会让下次回滚也退到坏配置。
        # ---- 先等窗口真的出现，再决定认不认这份配置（旧实例不算，见 Get-StartupSeconds）----
        # 进程活着但没有窗口（卡死型）不能算「跑通」：认成 last-good 后，
        # 下次真出事回滚就会退到这份卡死的配置。
        $startupSec = -1
        $windowSeen = $false
        if ($procAlive -gt 0) {
            if ($SimulateNoWindow) {
                Write-Log 'startup: simulated no-window (window wait skipped)'
            } else {
                $startupSec = Get-StartupSeconds -LaunchAt $started -FreshAt $freshAt -MaxSeconds $StartupWatchSeconds
            }
            if ($startupSec -ge 0) {
                $windowSeen = $true
                Write-Log ('startup: ' + $startupSec + ' s (window visible)')
            } else {
                Write-Log ('startup: not observed within ' + $StartupWatchSeconds + ' s (process alive, no window)')
            }
        } else {
            Write-Log 'startup: n/a (no fresh instance from this launch)'
        }

        $goodDir = Join-Path $SnapshotRoot 'last-good'
        if ($procAlive -gt 0 -and $windowSeen) {
            if (Test-Path $goodDir) { Remove-Item -LiteralPath $goodDir -Recurse -Force -ErrorAction SilentlyContinue }
            Copy-ConfigSnapshot -src $preDir -dst $goodDir
            Write-Log ('OK: refreshed last-good -> ' + $goodDir)
            # 只有「真的认证成功」才算这一轮跑通，才清两种失败计数。
            # 原先放在健康分支末尾，导致「有进程没窗口」这种卡死也把计数清掉、而且一声不响。
            if (Test-Path -LiteralPath $StateFile) {
                Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
                Write-Log 'reset: fail-streak cleared'
            }
            if (Test-Path -LiteralPath $HangFile) {
                Remove-Item -LiteralPath $HangFile -Force -ErrorAction SilentlyContinue
                Write-Log 'reset: hang-streak cleared'
            }

        } elseif ($procAlive -gt 0) {
            Write-Log 'SKIP: window never appeared - not certifying this config as last-good'
            # 卡死型故障：进程在、窗口一直不出来、也没有崩溃日志。以前这里完全静默，
            # 现在单独计数，连续两次才提醒一次（也可能只是启动慢，文案里说明）。
            $hang = 0
            if (Test-Path -LiteralPath $HangFile) {
                try {
                    $h = Get-Content -LiteralPath $HangFile -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
                    if ($h.count) { $hang = [int]$h.count }
                } catch {}
            }
            $hang++
            $hangJson = '{"count":' + $hang + ',"at":"' + (Get-Date -Format 's') + '"}'
            [System.IO.File]::WriteAllText($HangFile, $hangJson, (New-Object System.Text.UTF8Encoding($false)))
            Write-Log ('HANG: no window again (streak ' + $hang + ')')
            if ($hang -ge 2 -and -not $NoNotice) {
                Show-Notice ("DSH 已经连续 " + $hang + " 次「进程起来了、但窗口一直没出现」。`r`n`r`n可能是真卡死，也可能只是启动很慢（超过 " + $StartupWatchSeconds + " 秒还没出窗口）。`r`n`r`n建议：先再等一会儿看窗口会不会出来；始终不出来就完全退出 DSH 再启动一次。`r`n`r`n日志: " + $logFile) 48 60
            }
        } else {
            Write-Log ('SKIP: no fresh process named "' + $ProcessName + '" - not certifying this config as last-good')
        }

        # 不管这次健康与否都修剪，否则连续失败会让 pre-boot 无限堆积
        Prune-OldSnapshots
        Write-Log '=== watchdog end (healthy) ==='
        exit 0
    }

    # ---- 5. 失败：先读全文判断病因，再决定要不要回滚 ----
    Write-Log ('FAIL: ' + (($newLogs | ForEach-Object { $_.Name }) -join ', '))
    $authFail = $false
    $fingerprint = ''
    foreach ($l in $newLogs) {
        $body = @(Get-Content -LiteralPath $l.FullName -TotalCount 60 -ErrorAction SilentlyContinue)
        $errLine = @($body | Where-Object { $_ -match '^\s*(Error|TypeError|RangeError|ReferenceError|SyntaxError):' }) | Select-Object -First 1
        if (-not $errLine) {
            $errLine = @($body | Where-Object { $_ -match 'Error|failed|FAILED' }) | Select-Object -First 1
        }
        if (-not $errLine) {
            $errLine = @($body | Where-Object { $_ -match 'SIMULATED|web boot:' }) | Select-Object -First 1
        }
        if (-not $errLine) {
            $errLine = @($body | Where-Object { $_.Trim() -ne '' }) | Select-Object -First 1
        }
        if ($errLine -and ($errLine -match 'Web authentication failed')) { $authFail = $true }
        if ((-not $fingerprint) -and $errLine) { $fingerprint = ($errLine.Trim() -replace '\s+', ' ') }
        Write-Log ('  ' + $l.Name + ' -> ' + ((($body | Select-Object -First 14) -join ' | ') -replace '\s+', ' '))
    }
    if (-not $fingerprint) { $fingerprint = 'unknown failure (' + $newLogs.Count + ' log(s), no Error line)' }
    Write-Log ('fingerprint: ' + $fingerprint)

    # 同一指纹连续第几次？（健康启动会把计数清掉）
    $streak = 0
    if (Test-Path -LiteralPath $StateFile) {
        try {
            $st = Get-Content -LiteralPath $StateFile -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
            if ($st -and ($st.fingerprint -eq $fingerprint)) { $streak = [int]$st.count }
        } catch {}
    }
    $streak++
    try {
        $json = @{ fingerprint = $fingerprint; count = $streak; at = (Get-Date).ToString('o') } | ConvertTo-Json -Compress
        [System.IO.File]::WriteAllText($StateFile, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
    Write-Log ('streak: ' + $streak + '  (stop at ' + $StopAfterStreak + ')')

    # 认证失败不是配置问题：回滚只会把好配置换掉，重启也只会再失败一次
    if ($authFail) {
        $cookieDir = Join-Path $env:APPDATA '@deepseek-ai\dsh-desktop\Network'
        Write-Log 'AUTH-FAIL: "Web authentication failed" -> cookie store, not config. Nothing rolled back.'
        # 弹窗要停到人点掉，所以先把锁放了，否则下次启动会被这把锁挡住
        Release-Lock
        Write-Log 'released lock before notice'
        if (-not $NoNotice) {
            Show-Notice ("DSH 启动失败：认证失败（Web authentication failed）。`r`n`r`n这不是配置问题，所以没有回滚、也没有重启。`r`n`r`n处理办法：`r`n1. 先完全退出 DSH`r`n2. 删除这个目录里的 Cookies 文件`r`n   " + $cookieDir + "`r`n   （只删 Cookies 这一个，重启会自动重建）`r`n3. 再从桌面图标启动`r`n`r`n日志: " + $logFile) 48 0
        }
        Prune-OldSnapshots
        Write-Log '=== watchdog end (auth-fail, nothing rolled back) ==='
        exit 2
    }

    # 同一个指纹已经回滚过一次还这样：再来一轮也救不回来，停下来把原因交给人
    if ($streak -ge $StopAfterStreak) {
        Write-Log ('STOP: same failure ' + $streak + ' times in a row - another rollback would not help')
        Release-Lock
        Write-Log 'released lock before notice'
        if (-not $NoNotice) {
            Show-Notice ("DSH 连续 " + $streak + " 次以同样的方式启动失败：`r`n" + $fingerprint + "`r`n`r`n上次已经回滚过配置，仍然如此，所以这次不再回滚、也不再重启。`r`n`r`n看门狗日志: " + $logFile + "`r`n崩溃日志: " + $newLogs[0].Name) 48 0
        }
        Prune-OldSnapshots
        Write-Log '=== watchdog end (stopped after repeated failure) ==='
        exit 3
    }

    $goodDir = Join-Path $SnapshotRoot 'last-good'
    if (Test-Path $goodDir) {
        $restoreFrom = $goodDir
        Write-Log ('rollback source: ' + $goodDir)
    } else {
        $restoreFrom = $preDir
        Write-Log "WARN: no last-good, falling back to this run's pre-boot snapshot"
    }

    # 回滚前先把「现在这份坏掉的」另存一份：万一 last-good 才是过时的，还有东西可查
    $preRollback = Join-Path $SnapshotRoot ('pre-rollback-' + $started.ToString('yyyyMMdd-HHmmss'))
    $prCount = 0
    try {
        Copy-ConfigSnapshot -src $ProfileDir -dst $preRollback
        $prCount = @(Get-ChildItem -LiteralPath $preRollback -File -ErrorAction SilentlyContinue).Count
    } catch {}
    Write-Log ('backup of current profile -> ' + $preRollback + ' (' + $prCount + ' files)')

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

    # 必须重启前先放锁：新实例的看门狗看到这把握着旧 pid 的锁会直接 SKIP，
    # 等于「回滚重启出来的那个实例没有守护」。这个 bug 在 r3 到 b2 之间一直存在。
    Release-Lock
    Write-Log 'released lock before relaunch'

    if (-not $NoRelaunch) {
        # 必须走 start-dsh.vbs 重启，否则新实例没有看门狗（断链）；第 3 条会拦住无休止的重启
        $vbs = Join-Path $ScriptDir 'start-dsh.vbs'
        if (Test-Path -LiteralPath $vbs) {
            $wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
            Start-Process -FilePath $wscript -ArgumentList ('"' + $vbs + '"') | Out-Null
            Write-Log ('relaunched via ' + $vbs)
        } elseif ($ExePath -and (Test-Path $ExePath)) {
            Start-Process -FilePath $ExePath | Out-Null
            Write-Log 'relaunched (direct exe: start-dsh.vbs not found)'
        } else {
            Write-Log ('ERROR: exe not found: ' + $ExePath)
        }
    }

    if (-not $NoNotice) {
        Show-Notice ("DSH 启动失败，已回滚配置并重新启动。`r`n`r`n崩溃日志：" + ($newLogs[0].Name) + "`r`n恢复到：" + $restoreFrom + "`r`n坏掉的那份已另存：" + $preRollback + "`r`n`r`n详情见：" + $logFile) 48 0
    }
    Prune-OldSnapshots
    Write-Log '=== watchdog end (rolled back) ==='
    exit 1
}
catch {
    # fail-open：守护自己出错，绝不牵连已经启动的 App
    Write-Log ('EXCEPTION: ' + $_.Exception.Message)
    Write-Log ('  at ' + $_.InvocationInfo.ScriptName + ':' + $_.InvocationInfo.ScriptLineNumber)
    exit 0
}
finally {
    # PS 5.1 里 exit 也会跑 finally（已实测），所以锁一定能释放
    Release-Lock
}
