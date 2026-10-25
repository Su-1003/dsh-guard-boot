# install.ps1 - one-time setup for the DSH boot guard.
#
# What it does:
#   1. locates DeepSeek Harness.exe (uninstall registry -> existing .lnk -> common paths)
#   2. writes config.ini next to this script
#   3. seeds ~/.dsh/boot-snapshots/last-good from the CURRENT profile (so the very
#      first guarded failure already has something to roll back to)
#   4. creates a desktop shortcut that runs start-dsh.vbs via wscript.exe
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
#   powershell ... -File .\install.ps1 -ExePath "D:\apps\DeepSeek Harness.exe" -ProfileName desktop

param(
    [string]$ExePath     = '',
    [string]$ProfileName = 'desktop',
    [int]$WaitSeconds    = 20,
    [string]$ShortcutName = 'DSH (guarded)',
    [switch]$NoShortcut
)

$ErrorActionPreference = 'Stop'
$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptDir)) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }

function Write-Step { param([string]$m) Write-Host ('[install] ' + $m) }

function Find-DshExe {
    $cands = New-Object System.Collections.ArrayList

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

    $lnkDirs = @(
        [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('CommonDesktopDirectory'),
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs')
    )
    try {
        $wsh = New-Object -ComObject WScript.Shell
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
    } catch {}

    $rel = 'DeepSeek Harness\DeepSeek Harness.exe'
    [void]$cands.Add((Join-Path $env:LOCALAPPDATA ('Programs\' + $rel)))
    [void]$cands.Add((Join-Path $env:ProgramFiles $rel))
    [void]$cands.Add((Join-Path ${env:ProgramFiles(x86)} $rel))

    foreach ($c in $cands) {
        if ($c -and (Test-Path -LiteralPath $c)) { return (Resolve-Path -LiteralPath $c).Path }
    }
    return $null
}

# ---- 1. locate the exe ----
if ([string]::IsNullOrWhiteSpace($ExePath)) { $ExePath = Find-DshExe }
if ([string]::IsNullOrWhiteSpace($ExePath) -or -not (Test-Path -LiteralPath $ExePath)) {
    throw 'DeepSeek Harness.exe not found. Re-run with -ExePath "<full path to exe>".'
}
Write-Step ('exe: ' + $ExePath)

# ---- 2. write config.ini ----
$iniPath = Join-Path $ScriptDir 'config.ini'
$ini = @(
    '; written by install.ps1 - safe to edit by hand',
    ('ExePath=' + $ExePath),
    ('ProfileName=' + $ProfileName),
    ('WaitSeconds=' + $WaitSeconds)
)
[System.IO.File]::WriteAllText($iniPath, (($ini -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
Write-Step ('config: ' + $iniPath)

# ---- 3. seed last-good from the current profile ----
$profileDir = Join-Path $env:USERPROFILE ('.dsh\profiles\' + $ProfileName)
$snapRoot   = Join-Path $env:USERPROFILE '.dsh\boot-snapshots'
$goodDir    = Join-Path $snapRoot 'last-good'
$files = @('package.json','pnpm-lock.yaml','pnpm-workspace.yaml','cordis.yml','cordis.patch.yml','compatibility.json')

# 只有凑齐 6 个文件才把它当基线：半份快照一旦被当成 last-good，
# 之后每次启动都会回滚到一份可能根本起不来的配置（见 README「限制」一节）。
$total = $files.Count
$available = 0
if (Test-Path $profileDir) {
    foreach ($f in $files) { if (Test-Path (Join-Path $profileDir $f)) { $available++ } }
}
if ($available -eq $total) {
    if (-not (Test-Path $goodDir)) { New-Item -ItemType Directory -Force -Path $goodDir | Out-Null }
    foreach ($f in $files) {
        Copy-Item -LiteralPath (Join-Path $profileDir $f) -Destination (Join-Path $goodDir $f) -Force
    }
    Write-Step ('last-good seeded: ' + $goodDir + ' (' + $total + ' of ' + $total + ' files)')
}
elseif ($available -eq 0) {
    Write-Step ('WARN: profile not found or empty - last-good NOT seeded: ' + $profileDir)
}
else {
    Write-Step ('WARN: profile is incomplete (' + $available + ' of ' + $total + ' files) - last-good NOT seeded.')
    Write-Step '      seeding a partial snapshot could roll DSH back to a config that cannot boot.'
    Write-Step '      launch DSH once normally instead: the guard certifies a real good snapshot by itself.'
}

# ---- 4. desktop shortcut ----
$vbs = Join-Path $ScriptDir 'start-dsh.vbs'
$ico = Join-Path $ScriptDir 'assets\logo.ico'
if (Test-Path $ico) { $iconLoc = $ico + ',0' } else { $iconLoc = $ExePath + ',0' }
if (-not $NoShortcut) {
    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) ($ShortcutName + '.lnk')
    $wsh = New-Object -ComObject WScript.Shell
    $s = $wsh.CreateShortcut($lnk)
    $s.TargetPath       = (Join-Path $env:SystemRoot 'System32\wscript.exe')
    $s.Arguments        = '"' + $vbs + '"'
    $s.WorkingDirectory = $ScriptDir
    $s.IconLocation     = $iconLoc
    $s.WindowStyle      = 1
    $s.Description      = 'DeepSeek Harness (boot guard: snapshot + auto rollback)'
    $s.Save()
    Write-Step ('shortcut: ' + $lnk)
}

# ---- 5. dry self-check ----
$ps = Join-Path $ScriptDir 'watchdog.ps1'
if (Test-Path $ps) {
    Write-Step 'self-check: parsing watchdog.ps1'
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($ps, [ref]$null, [ref]$errs)
    if ($errs -and $errs.Count -gt 0) {
        Write-Step ('WARN: ' + $errs.Count + ' parse error(s) in watchdog.ps1')
    } else {
        Write-Step 'self-check: OK'
    }
}

Write-Step 'done. Double-click the desktop shortcut to start DSH with the guard.'
