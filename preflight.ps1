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
    [switch]$NoPopup,
    [string]$LogDir     = '',
    [int]$RemindGap     = 10,
    [string]$StateFile  = ''
)

$ErrorActionPreference = 'Continue'

$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptDir)) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }

if ([string]::IsNullOrWhiteSpace($CookieDir)) {
    $CookieDir = Join-Path $env:APPDATA '@deepseek-ai\dsh-desktop\Network'
}
if ([string]::IsNullOrWhiteSpace($LogDir)) { $LogDir = Join-Path $ScriptDir 'logs' }
if ([string]::IsNullOrWhiteSpace($StateFile)) { $StateFile = Join-Path $LogDir 'preflight-state.json' }

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
    # -NoPopup：只写日志、不弹窗（测试用）。返回 0 等于「用户没点」，
    # 所以任何需要用户点「是」才执行的动作都不会发生。
    if ($NoPopup) {
        Write-PLog ('popup suppressed: ' + (($text -split "`r`n")[0]))
        return 0
    }
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

# 弹窗节流的小工具：同一个 state 文件同时服务「告警」与「清理询问」两条分支
function Get-PromptState {
    param([string]$path)

    $o = [pscustomobject]@{ date = ''; count = -1 }
    if (Test-Path -LiteralPath $path) {
        try {
            $st = Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
            if ($st) { $o.date = [string]$st.date; $o.count = [int]$st.count }
        } catch {}
    }
    return $o
}

function Test-ShouldPrompt {
    param($State, [int]$Count, [int]$Gap, [string]$Today)

    if ($State.date -ne $Today) { return $true }
    if ($State.count -lt 0) { return $true }
    if ($Count -ge ($State.count + $Gap)) { return $true }
    return $false
}

function Save-PromptState {
    param([string]$path, [int]$Count)

    try {
        $json = '{"date":"' + (Get-Date).ToString('yyyy-MM-dd') + '","count":' + $Count + '}'
        [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
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
        # 清理询问也要节流：否则每天每次启动都弹一个要你点「是」的框
        $promptState = Get-PromptState $StateFile
        if (-not (Test-ShouldPrompt -State $promptState -Count $count -Gap $RemindGap -Today ((Get-Date).ToString('yyyy-MM-dd')))) {
            Write-PLog ('clean prompt throttled (asked today at ' + $promptState.count + ', now ' + $count + ')')
            exit 0
        }
        $answer = Show-Popup ("DSH 的认证 cookie 有 " + $count + " 条，超过清理线 " + $CleanCount + "。`r`n`r`n" +
                              "它们越积越多时，DSH 启动会报 `"Web authentication failed`"。`r`n`r`n" +
                              "现在备份并清理到只剩登录凭证吗？`r`n（会先复制一份 Cookies.bak-时间戳，失败可还原）") 52 60
        Save-PromptState $StateFile $count
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
                # 兜底：读不到 node:sqlite 时不能把活推回给用户。
                # 已经备份过，直接整删 Cookies —— Chromium 下次启动会重建，代价是要重新登录。
                Write-PLog 'clean failed (node not available or db refused) - falling back to deleting the whole file'
                try {
                    Remove-Item -LiteralPath $cookies -Force -ErrorAction Stop
                    Write-PLog ('deleted whole cookie db (backup kept: ' + $backup + ')')
                    Show-Popup ("清理没有成功（读不到 node:sqlite），已经把整个 Cookies 文件删掉。`r`n`r`n" +
                                "原文件备份在：`r`n" + $backup + "`r`n`r`nDSH 启动后会重建 cookie，需要重新登录一次。") 64 45 | Out-Null
                } catch {
                    Write-PLog ('fallback delete FAILED: ' + $_.Exception.Message)
                    Show-Popup ("清理没有成功，删除文件也失败了：" + $_.Exception.Message + "`r`n`r`n请手动删除这个文件后再启动：`r`n" + $cookies) 16 60 | Out-Null
                }
            }
        } else {
            Write-PLog ('user declined cleaning (' + $answer + ')')
        }
        exit 0
    }

    if (-not $Quiet) {
        # 只在「今天还没提醒过」或「比上次提醒时多涨了 RemindGap 条」时弹窗，
        # 否则每次都弹会让人把提示当背景噪音，而且它会阻塞启动（vbs 是同步等待）。
        $today = (Get-Date).ToString('yyyy-MM-dd')
        $lastDate = ''
        $lastCount = -1
        if (Test-Path -LiteralPath $StateFile) {
            try {
                $st = Get-Content -LiteralPath $StateFile -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
                if ($st) { $lastDate = [string]$st.date; $lastCount = [int]$st.count }
            } catch {}
        }
        $shouldShow = ($lastDate -ne $today) -or ($lastCount -lt 0) -or ($count -ge ($lastCount + $RemindGap))
        if ($shouldShow) {
            Show-Popup ("DSH 的认证 cookie 已经有 " + $count + " 条（提示线 " + $WarnCount + "）。`r`n`r`n" +
                        "还不用清理，但如果启动开始报 `"Web authentication failed`"，`r`n就是它了。`r`n`r`n" +
                        "（今天只会提示这一次，条数涨到 " + ($count + $RemindGap) + " 条以上会再提醒）") 48 10 | Out-Null
            try {
                $j = @{ date = $today; count = $count; at = (Get-Date).ToString('o') } | ConvertTo-Json -Compress
                [System.IO.File]::WriteAllText($StateFile, $j, (New-Object System.Text.UTF8Encoding($false)))
                Write-PLog ('warned and state updated (' + $count + ')')
            } catch {}
        } else {
            Write-PLog ('warn throttled (already warned today at ' + $lastCount + ', now ' + $count + ', gap ' + $RemindGap + ')')
        }
    }
    exit 0
}
catch {
    Write-PLog ('EXCEPTION: ' + $_.Exception.Message)
    exit 0
}
