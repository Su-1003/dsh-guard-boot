<div align="center">

![dsh-guard-boot](assets/logo-180.png)


# dsh-guard-boot

<p>给 <b>DeepSeek Harness 桌面版（Windows）</b> 用的一层启动保险：<br>
启动路径上不加等待，旁边挂一个看门狗 —— 发现启动失败，自动回滚配置并重新拉起。</p>

<p>
  <img alt="license" src="https://img.shields.io/badge/license-MIT-2ea043?style=flat-square">
  <img alt="dependencies" src="https://img.shields.io/badge/dependencies-none-2ea043?style=flat-square">
  <img alt="build step" src="https://img.shields.io/badge/build%20step-none-8b949e?style=flat-square">
  <img alt="platform" src="https://img.shields.io/badge/platform-Windows-0078d4?style=flat-square">
  <img alt="powershell" src="https://img.shields.io/badge/powershell-5.1%2B-5391FE?style=flat-square">
  <img alt="tested on" src="https://img.shields.io/badge/tested%20on-DSH%200.2.1--rc.3-1f6feb?style=flat-square">
</p>

<p><sub><b>简体中文</b> · <a href="#english">English</a></sub></p>

</div>

> 它**不是插件**。它完全住在 DSH 外面 —— 不写 profile，不进 bundle 名册，不参与 boot。DSH 崩了它还在。

## 获取

```powershell
git clone https://github.com/Su-1003/dsh-guard-boot.git
cd dsh-guard-boot
```

没有 git 就下 [zip](https://github.com/Su-1003/dsh-guard-boot/archive/refs/heads/main.zip) 解压，效果一样 —— 它只是个文件夹，没有依赖、不用 `npm install`。

## 为什么不在 DSH 里做

因为「守门人不能住在门里」。真实经历：

- 装了一个第三方插件，重启后 GUI 弹「应用无法启动」：`web boot: 1 entry did not activate` / `pending (waiting for service: settingsScope)`；
- 唯一的自救按钮是「**禁用第三方插件**」，一点下去 25 个 bundle 全被停用，配置被替换成极简版，事后要手工从备份还原；
- 那个插件之所以拖垮启动，正是因为它自己要求在 boot 时装进 cordis 树。

所以这层保险放在进程之外：它读文件、写文件、杀进程，从不被 DSH 加载，也不会被「禁用第三方插件」一键停掉。

## 它做什么

| 场景 | 看门狗看到什么 | 它做什么 |
|---|---|---|
| 正常启动 | 20 秒内没有新的 `crash-*.log` | 把当前 6 个配置存成 `last-good`，安静退出 |
| 启动被配置/插件拖垮 | 出现新的 `crash-*.log` | 杀进程 → 回滚 6 个文件 → 重新拉起 → 弹窗告知 |
| 连快照都写不出来 | 快照得到 0 个文件 | 记一行日志就退出，**不碰你的任何文件**（fail-open） |
| 进程根本没起来 | 进程数为 0 | **不刷新 `last-good`**，防止坏配置被认证成好配置 |

判据只看崩溃日志，**不看进程存活**：`web boot` 失败时进程是活得好好的，只有日志是新的。

## 快照与回滚点

每次从图标启动都先拍一份 `pre-boot-<时间戳>`（保留最近 5 份，旧的自动删）；20 秒内没崩，再把当前配置刷成 `last-good`。

回滚**不按时间挑**，用的永远是 `last-good` —— 也就是「**上一次启动成功的配置**」。这点很关键：失败的那次启动不会刷新它（进程数为 0 时更是直接跳过），所以回滚点不会退化成那份坏配置。

快照里的 6 个文件：

| 文件 | 管什么 |
|---|---|
| `package.json` | bundle 名册、依赖 |
| `pnpm-lock.yaml` | 依赖版本锁定 |
| `pnpm-workspace.yaml` | workspace 配置 |
| `cordis.yml` | 启动时由 boot 重写，通常内容极少 |
| `cordis.patch.yml` | 插件配置覆盖层，真正容易坏的那个 |
| `compatibility.json` | 插件 → 支持的 DSH 版本映射，被改坏会让插件判定失真 |

## 安装

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

`install.ps1` 会：找 exe（卸载表 → 已有快捷方式 → 常见路径）→ 写 `config.ini` → 用当前配置预置一份 `last-good` → 在桌面建快捷方式。

找不到 exe 时显式指定：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -ExePath "D:\apps\DeepSeek Harness\DeepSeek Harness.exe"
```

之后日常用桌面上的 **DSH（守护启动）** 图标启动；原来的 `DeepSeek Harness` 图标保持不动，随时可以回退。

> 快捷方式默认名是 `DSH (guarded)`，想改成自己的名字：`-ShortcutName "DSH（守护启动）"`。图标默认用 `assets/logo.ico`，删掉该文件则回退到 exe 自带图标。

## 配置（`config.ini`）

```ini
ExePath=E:\path\to\DeepSeek Harness.exe
ProfileName=desktop
WaitSeconds=20
```

`ProfileName` 对应 `%USERPROFILE%\.dsh\profiles\<name>`。`WaitSeconds` 是判定窗口，默认 20 秒。

## 文件

| 文件 | 作用 |
|---|---|
| `install.ps1` | 一次性安装：找路径、写配置、预置 last-good、建快捷方式 |
| `start-dsh.vbs` | 双击入口。先跑 cookie 体检，再起 exe，最后隐藏起看门狗 |
| `watchdog.ps1` | 快照、判定、回滚 |
| `preflight.ps1` | 启动前的 cookie 体检（只在 exe 起来之前读得到那个库） |
| `config.ini` | 由 install.ps1 生成，可手改 |
| `assets/logo.ico` | 快捷方式图标（install.ps1 优先用它） |
| `assets/logo.png` | 仓库头像 / 文档用图（`assets/make-logo.py` 用 Pillow 生成） |

快照目录：`%USERPROFILE%\.dsh\boot-snapshots\`（`last-good\` 一份 + 最多 5 份 `pre-boot-*\`，合计约 1 MB）
日志目录：`logs\`（每次启动一份 `watchdog-<时间戳>.log`）

### 启动耗时

健康启动的日志里会多一行：

```
startup: 12 s (window visible)
```

它量的是 **exe 起到窗口真正出现**（`MainWindowHandle` 非 0）的秒数，最多等 `-StartupWatchSeconds`（默认 120 秒）。
只认「本次启动」的新实例——旧实例的窗口一直开着，不筛的话每个数字都会是 0。

另外两种取值也是信息：

| 日志 | 含义 |
|---|---|
| `startup: n/a (no fresh instance from this launch)` | 这次没有新进程（重复双击、实例已在跑），没东西可量 |
| `startup: not observed within 120 s (process alive, no window)` | 进程活着但窗口一直没出来 —— 卡在启动里了，值得看一眼 |

### 认得出哪些失败

不是所有失败都该回滚配置。看门狗读崩溃日志的**全文**（最多 60 行），先判断病因：

| 崩溃日志里看到 | 它做什么 | 退出码 |
|---|---|---|
| `Web authentication failed` | **不回滚、也不重启**，只弹窗给清 cookie 的步骤 —— 坏的是登录状态，回滚只会把好配置换掉 | 2 |
| 其它错误（或读不出错误文本） | 备份当前 profile → 回滚 `last-good` → 经 `start-dsh.vbs` 重启，新实例同样带守护 | 1 |
| 同一个错误连续第 2 次 | **停手**：已经回滚过一次还这样，再来一次也不会好，把原因交给人 | 3 |

「同一个错误」用崩溃日志里第一行 Error 文本做指纹（记在 `fail-streak.json`），健康启动一次就清零。
回滚之前，当前那份配置会先另存为 `pre-rollback-<时间戳>\` —— 万一 `last-good` 才是过时的，还有东西可查。

### 启动前的 cookie 体检

`preflight.ps1` 由 `start-dsh.vbs` 在**起 exe 之前**同步调用 —— 那一瞬间 cookie 库还没被 Chromium 锁住，读得到；DSH 一跑起来就连 `FileShare.ReadWrite` 也打不开。

- 数的是 `dsh-auth-*` 的条数（优先用 node 读 sqlite；没有 node 就退回字节扫描，只判量级）
- 超过 `-WarnCount`（默认 15）→ 提示一次，不动手
- 超过 `-CleanCount`（默认 30）→ 弹确认框，点「是」才先备份 `Cookies.bak-<时间戳>` 再清理

它**从不自动清**（那会把人踢下线），也不会阻塞启动：任何异常都只是写一行日志。

## 边界（老实说）

- **只救配置层**：插件/配置把启动弄坏这一类。exe 损坏、asar 被覆盖、磁盘满、端口被占 —— 回滚配置没用，但它会在日志里写清楚。
- **只在那 20 秒窗口里看一次**：运行中闪退、用一半 OOM 崩溃，它不知道。
- **只认崩溃日志**：如果某种失败模式不写 `crash-*.log`，它会误判为健康。日志写了、但里面没有可识别的错误文本时，指纹记成 `unknown failure`，仍然走回滚。
- **只在从该快捷方式启动时生效**：从开始菜单或命令行启动 DSH 不会有保护。
- **重复双击不会污染 last-good**：判定只认「启动后 15 秒内新出现的进程」，已经在跑的旧实例不算数，所以"其实没启动成功"的那次不会把配置认证成 good。
- **认得出「认证失败」这种配置救不了的病**，见下一节 —— 它不会在同一个坑里无限回滚。

## 演练

不碰真 profile、不杀真进程：

```powershell
$ps5 = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
& $ps5 -NoProfile -ExecutionPolicy Bypass -File .\watchdog.ps1 `
  -ProfileDir  D:\tmp\profile `
  -SnapshotRoot D:\tmp\snaps `
  -CrashLogDir D:\tmp\crashlog `
  -ProcessName nonexistent-xyz `
  -WaitSeconds 1 -KeepProcesses -NoRelaunch -NoNotice -LogDir D:\tmp\logs `
  -SimulateCrash
```

`-SimulateCrash` 造一份假崩溃日志逼它走回滚分支。

## 卸载

删掉快捷方式即可；本目录与 `%USERPROFILE%\.dsh\boot-snapshots\` 都是纯文件，随时可删，DSH 本身不受影响。

## English

A sidecar boot guard for **DeepSeek Harness (desktop, Windows)**. Double-clicking the launcher starts the app immediately and fires a hidden watchdog alongside it:

- 20 s after launch, if no new `crash-*.log` appeared → snapshot the five profile config files as `last-good`, exit quietly.
- if a new crash log appeared → kill the app, restore those files from `last-good`, relaunch, show a dialog.

It deliberately lives **outside** DSH: no plugin, no profile entry, nothing loaded by boot. A guard that ships as a plugin dies together with the thing it guards — that is exactly how the incident that motivated this tool played out.

Install with `install.ps1`, configure via `config.ini`, uninstall by deleting the shortcut. MIT.

## 许可

MIT
