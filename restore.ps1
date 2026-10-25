# restore.ps1 - manual restore of one config snapshot into the DSH profile
#
# Why: watchdog.ps1 only rolls back when a *startup fails*. If a config change
# starts fine but you simply want it gone, previously the only way was to open
# boot-snapshots\last-good and copy the files by hand.
#
# Safety rules (all of them matter):
#   1. Refuses to run while DSH is running - it rewrites cordis.yml / package.json
#      on exit, so restoring under a live instance just gets overwritten. -Force bypasses.
#   2. Saves the current profile as pre-restore-<timestamp> first, so a restore
#      is itself undoable.
#   3. By default only overwrites files that exist in the snapshot. Files the
#      snapshot does not contain are left alone and reported.
#   4. -Prune additionally deletes managed files (only the 6 names below) that
#      the snapshot does not contain. Nothing else is ever touched.
#   5. -DryRun prints the plan and changes nothing.
#
# Exit codes: 0 ok / 1 usage error / 2 DSH is running / 3 snapshot not found

param(
    [string]$From         = '',
    [switch]$List,
    [switch]$DryRun,
    [switch]$Prune,
    [switch]$Force,
    [string]$ProfileName  = '',
    [string]$ProfileDir   = '',
    [string]$SnapshotRoot = '',
    [string]$ProcessName  = 'DeepSeek Harness',
    [string]$ConfigFile   = ''
)

$ErrorActionPreference = 'Stop'

# 受管文件：与 watchdog.ps1 的 $SnapFiles 必须一致
$ManagedFiles = @('package.json','pnpm-lock.yaml','pnpm-workspace.yaml','cordis.yml','cordis.patch.yml','compatibility.json')

function Write-R {
    param([string]$msg)
    Write-Host ('restore: ' + $msg)
}

function Read-IniLocal {
    param([string]$path)
    $h = @{}
    if (-not (Test-Path -LiteralPath $path)) { return $h }
    foreach ($line in (Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith(';') -or $t.StartsWith('#')) { continue }
        $i = $t.IndexOf('=')
        if ($i -lt 1) { continue }
        $h[$t.Substring(0, $i).Trim()] = $t.Substring($i + 1).Trim()
    }
    return $h
}

function Get-ManagedIn {
    param([string]$dir)
    $found = @()
    foreach ($f in $ManagedFiles) { if (Test-Path -LiteralPath (Join-Path $dir $f)) { $found += $f } }
    return $found
}

try {
    $ScriptDir = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($ScriptDir)) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }

    if ([string]::IsNullOrWhiteSpace($ConfigFile)) { $ConfigFile = Join-Path $ScriptDir 'config.ini' }
    $cfg = Read-IniLocal $ConfigFile
    if ([string]::IsNullOrWhiteSpace($ProfileName) -and $cfg.ContainsKey('ProfileName')) { $ProfileName = $cfg['ProfileName'] }
    if ([string]::IsNullOrWhiteSpace($ProfileName)) { $ProfileName = 'desktop' }
    if ([string]::IsNullOrWhiteSpace($ProfileDir)) { $ProfileDir = Join-Path $env:USERPROFILE ('.dsh\profiles\' + $ProfileName) }
    if ([string]::IsNullOrWhiteSpace($SnapshotRoot)) { $SnapshotRoot = Join-Path $env:USERPROFILE '.dsh\boot-snapshots' }

    Write-R ('profile   : ' + $ProfileDir)
    Write-R ('snapshots : ' + $SnapshotRoot)

    if (-not (Test-Path -LiteralPath $SnapshotRoot)) {
        Write-R 'ERROR: snapshot root does not exist yet (no launch has been guarded)'
        exit 3
    }

    if ($List) {
        Write-R 'available snapshots:'
        $dirs = @(Get-ChildItem -LiteralPath $SnapshotRoot -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
        if ($dirs.Count -eq 0) { Write-R '  (none)' }
        foreach ($d in $dirs) {
            $n = @(Get-ManagedIn $d.FullName).Count
            $tag = ''
            if ($d.Name -eq 'last-good') { $tag = '   <- rollback target' }
            Write-R ('  ' + $d.Name.PadRight(30) + ' ' + $d.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $n + ' file(s)' + $tag)
        }
        exit 0
    }

    if ([string]::IsNullOrWhiteSpace($From)) {
        Write-R 'ERROR: -From is required (or use -List to see what is available)'
        exit 1
    }

    $src = ''
    if (Test-Path -LiteralPath $From -PathType Container) {
        $src = (Resolve-Path -LiteralPath $From).Path
    } else {
        $cand = Join-Path $SnapshotRoot $From
        if (Test-Path -LiteralPath $cand -PathType Container) { $src = (Resolve-Path -LiteralPath $cand).Path }
    }
    if ($src -eq '') {
        Write-R ('ERROR: snapshot not found: ' + $From)
        Write-R 'run with -List to see available names'
        exit 3
    }
    Write-R ('source    : ' + $src)

    $srcFiles = @(Get-ManagedIn $src)
    if ($srcFiles.Count -eq 0) {
        Write-R 'ERROR: that snapshot contains none of the managed config files'
        exit 3
    }
    if (-not (Test-Path -LiteralPath $ProfileDir)) {
        Write-R ('ERROR: profile dir not found: ' + $ProfileDir)
        exit 1
    }

    # 0) 看门狗正在回滚时也不要写：它第一时间就把 DSH 杀掉了，所以下面那条
    #    「DSH 在跑就拒绝」拦不住它，只有锁文件能说明「有别的进程正在动 profile」。
    $lockFile = Join-Path $SnapshotRoot 'watchdog.lock'
    if (Test-Path -LiteralPath $lockFile) {
        $lockRaw = ''
        try { $lockRaw = [string](Get-Content -LiteralPath $lockFile -Raw -ErrorAction SilentlyContinue) } catch {}
        $lm = [regex]::Match($lockRaw, 'pid=(\d+)')
        if ($lm.Success) {
            $lockPid = [int]$lm.Groups[1].Value
            $lockProc = Get-Process -Id $lockPid -ErrorAction SilentlyContinue
            if ($lockProc -and $lockProc.ProcessName -match '^(powershell|pwsh)$') {
                if (-not $Force) {
                    Write-R ('REFUSED: a watchdog is running (pid ' + $lockPid + ') and may be rewriting the profile right now.')
                    Write-R 'It kills DSH before restoring, so the "DSH is running" check below cannot catch it.'
                    Write-R 'Wait a few seconds for it to finish, then run this again. (-Force to override anyway.)'
                    exit 2
                }
                Write-R ('WARN: forcing while a watchdog (pid ' + $lockPid + ') holds the lock')
            }
        }
    }

    # 1) 正在运行就拒绝：退出时 DSH 会重写 cordis.yml / package.json
    $running = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0 -and -not $Force) {
        Write-R ('REFUSED: ' + $running.Count + ' process(es) named "' + $ProcessName + '" are running.')
        Write-R 'DSH rewrites cordis.yml / package.json when it exits, so a restore now would be overwritten.'
        Write-R 'Quit DSH completely first, then run this again. (-Force to override anyway.)'
        exit 2
    }
    if ($running.Count -gt 0) { Write-R ('WARN: forcing while ' + $running.Count + ' process(es) are running') }

    $curFiles = @(Get-ManagedIn $ProfileDir)
    $toCopy = @()
    $missing = @()
    foreach ($f in $ManagedFiles) {
        if ($srcFiles -contains $f) { $toCopy += $f } else { $missing += $f }
    }
    $toPrune = @()
    if ($Prune) {
        foreach ($f in $curFiles) { if ($srcFiles -notcontains $f) { $toPrune += $f } }
    }

    Write-R ('will copy : ' + ($(if ($toCopy.Count) { $toCopy -join ', ' } else { '(nothing)' })))
    if ($missing.Count) { Write-R ('not in snapshot (kept as is): ' + ($missing -join ', ')) }
    if ($Prune) {
        Write-R ('will delete (managed names only): ' + ($(if ($toPrune.Count) { $toPrune -join ', ' } else { '(nothing)' })))
    }

    if ($DryRun) {
        Write-R 'DRY RUN - nothing was changed'
        exit 0
    }

    # 2) 恢复前先把当前这份存起来
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $store = Join-Path $SnapshotRoot ('pre-restore-' + $stamp)
    New-Item -ItemType Directory -Force -Path $store | Out-Null
    $saved = 0
    foreach ($f in $curFiles) {
        Copy-Item -LiteralPath (Join-Path $ProfileDir $f) -Destination (Join-Path $store $f) -Force
        $saved++
    }
    Write-R ('current profile saved to ' + $store + ' (' + $saved + ' file(s))')

    # 3) 复制
    $n = 0
    foreach ($f in $toCopy) {
        Copy-Item -LiteralPath (Join-Path $src $f) -Destination (Join-Path $ProfileDir $f) -Force
        Write-R ('  copied ' + $f)
        $n++
    }

    # 4) 可选：删掉受管名单里、快照没有的文件
    $d = 0
    foreach ($f in $toPrune) {
        Remove-Item -LiteralPath (Join-Path $ProfileDir $f) -Force -ErrorAction SilentlyContinue
        Write-R ('  deleted ' + $f)
        $d++
    }

    Write-R ('done: ' + $n + ' restored, ' + $d + ' deleted, backup at ' + $store)
    Write-R 'start DSH from the desktop icon when you are ready'
    exit 0
}
catch {
    Write-R ('ERROR: ' + $_.Exception.Message)
    exit 1
}
