# preflight.ps1 — 启动前的 cookie 体检（数一数 DSH 的认证 cookie 有多少条）
#
# 为什么必须在 exe 启动之前跑：
#   DSH 跑起来后 %APPDATA%\@deepseek-ai\dsh-desktop\Network\Cookies 被 Chromium 独占锁定，
#   连 FileShare.ReadWrite 都打不开；只有 exe 还没起来的那一刻才读得到。
#
# 它只做两件事，都是 fail-open（任何异常都不阻塞启动）：
#   1. 条数 > WarnCount  → 提示一次（不动作）
#   2. 条数 > CleanCount → 弹出「要不要现在备份并清理」的确认框，用户点「是」才动
#
# 用法：start-dsh.vbs 会在起 exe 前同步调用；也可以手动跑来查看当前条数。

param(
    [string]$CookieDir  = '',
    [int]$WarnCount     = 15,
    [int]$CleanCount    = 30,
    [switch]$Quiet,
    [string]$LogDir     = ''
)

$ErrorActionPreference = 'Continue'

$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptDir)) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }

if ([string]::IsNullOrWhiteSpace($CookieDir)) {
    $CookieDir = Join-Path $env:APPDATA '@deepseek-ai\dsh-desktop\Network'
}
if ([string]::IsNullOrWhiteSpace($LogDir)) { $LogDir = Join-Path $ScriptDir 'logs' }

function Write-PLog {
    param([string]$msg)
    try {
        if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
        $line = '[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $msg
        Add-Content -LiteralPath (Join-Path $LogDir ('preflight-' + (Get-Date -Format 'yyyyMMdd') + '.log')) -Value $line -Encoding UTF8
    } catch {}
}

function Show-Popup {
    param([string]$text, [int]$icon, [int]$timeout)
    try {
        $w = New-Object -ComObject WScript.Shell
        return $w.Popup($text, $timeout, 'DSH 启动前体检', $icon)
    } catch { return -1 }
}

# 用 node 读 sqlite（准确）；读不到就返回 -1
function Get-AuthCookieCount {
    param([string]$path)

    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) { return -1 }

    $js = @'
const { DatabaseSync } = require("node:sqlite");
const db = new DatabaseSync(process.argv[2], { readOnly: true });
const row = db.prepare("select count(*) as c from cookies where name like 'dsh-auth-%'").get();
console.log(row.c);
db.close();
'@
    $tmp = Join-Path $env:TEMP ('dsh-cookie-count-' + [guid]::NewGuid().ToString('N') + '.cjs')
    try {
        [System.IO.File]::WriteAllText($tmp, $js, (New-Object System.Text.UTF8Encoding($false)))
        $out = & $node.Source '--no-warnings' $tmp $path 2>$null
        if ($LASTEXITCODE -eq 0 -and ($out -join '') -match '^\d+$') { return [int](($out -join '').Trim()) }
    } catch {}
    finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    return -1
}

# 兜底：按字节扫 'dsh-auth-' 出现次数（近似值，只用来判断量级）
function Get-AuthCookieCountByScan {
    param([string]$path)
    try {
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $s = [System.Text.Encoding]::GetEncoding(28591).GetString($bytes)
        return ([regex]::Matches($s, 'dsh-auth-')).Count
    } catch { return -1 }
}

function Remove-AuthCookies {
    param([string]$path)

    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) { return -1 }

    $js = @'
const { DatabaseSync } = require("node:sqlite");
const db = new DatabaseSync(process.argv[2]);
const r = db.prepare("delete from cookies where name like 'dsh-auth-%'").run();
console.log(r.changes);
db.close();
'@
    $tmp = Join-Path $env:TEMP ('dsh-cookie-clean-' + [guid]::NewGuid().ToString('N') + '.cjs')
    try {
        [System.IO.File]::WriteAllText($tmp, $js, (New-Object System.Text.UTF8Encoding($false)))
        $out = & $node.Source '--no-warnings' $tmp $path 2>$null
        if ($LASTEXITCODE -eq 0 -and ($out -join '') -match '^\d+$') { return [int](($out -join '').Trim()) }
    } catch {}
    finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    return -1
}

try {
    $cookies = Join-Path $CookieDir 'Cookies'
    if (-not (Test-Path -LiteralPath $cookies)) {
        Write-PLog ('cookie db not found: ' + $cookies + ' (skip)')
        exit 0
    }

    $size = (Get-Item -LiteralPath $cookies).Length
    $count = Get-AuthCookieCount $cookies
    $how = 'sqlite'
    if ($count -lt 0) { $count = Get-AuthCookieCountByScan $cookies; $how = 'byte-scan (approx)' }

    if ($count -lt 0) {
        Write-PLog ('cookie db unreadable (locked or corrupt): ' + $cookies + ' (skip)')
        exit 0
    }

    Write-PLog ('file=' + $size + ' B  auth-cookies=' + $count + '  method=' + $how + '  warn>' + $WarnCount + ' clean>' + $CleanCount)

    if ($count -le $WarnCount) { exit 0 }

    if ($count -gt $CleanCount -and -not $Quiet) {
        $answer = Show-Popup ("DSH 的认证 cookie 有 " + $count + " 条，超过清理线 " + $CleanCount + "。`r`n`r`n" +
                              "它们越积越多时，DSH 启动会报 `"Web authentication failed`"。`r`n`r`n" +
                              "现在备份并清理到只剩登录凭证吗？`r`n（会先复制一份 Cookies.bak-时间戳，失败可还原）") 52 60
        if ($answer -eq 6) {
            $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
            $backup = Join-Path $CookieDir ('Cookies.bak-' + $stamp)
            try {
                Copy-Item -LiteralPath $cookies -Destination $backup -Force -ErrorAction Stop
                Write-PLog ('backup -> ' + $backup)
            } catch {
                Write-PLog ('backup FAILED: ' + $_.Exception.Message)
                Show-Popup ("备份失败，没有清理：" + $_.Exception.Message) 16 30 | Out-Null
                exit 0
            }

            $removed = Remove-AuthCookies $cookies
            if ($removed -ge 0) {
                Write-PLog ('cleaned ' + $removed + ' auth cookie(s)')
            } else {
                Write-PLog 'clean failed (node not available or db refused) - telling the user to delete the file'
                Show-Popup ("清理没有成功（读不到 node:sqlite）。`r`n`r`n请手动删除这个文件后再启动：`r`n" + $cookies) 48 60 | Out-Null
            }
        } else {
            Write-PLog ('user declined cleaning (' + $answer + ')')
        }
        exit 0
    }

    if (-not $Quiet) {
        Show-Popup ("DSH 的认证 cookie 已经有 " + $count + " 条（提示线 " + $WarnCount + "）。`r`n`r`n" +
                    "还不用清理，但如果启动开始报 `"Web authentication failed`"，`r`n就是它了。") 48 20 | Out-Null
    }
    exit 0
}
catch {
    Write-PLog ('EXCEPTION: ' + $_.Exception.Message)
    exit 0
}
