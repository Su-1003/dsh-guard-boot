# dsh-guard-boot

给 **DeepSeek Harness 桌面版（Windows）** 用的一层启动保险：**启动路径上不加等待**，旁边挂一个看门狗，发现启动失败就自动回滚配置并重启。

> 它**不是插件**。它完全住在 DSH 外面——不写 profile，不进 bundle 名册，不参与 boot。DSH 崩了它还在。

## 获取

```powershell
git clone https://github.com/Su-1003/dsh-guard-boot.git
cd dsh-guard-boot
```

没有 git 就下 [zip](https://github.com/Su-1003/dsh-guard-boot/archive/refs/heads/main.zip) 解压，效果一样——它只是个文件夹，没有依赖、不用 `npm install`。

## 为什么不在 DSH 里做

因为「守门人不能住在门里」。真实经历：

- 装了一个第三方插件，重启后 GUI 弹「应用无法启动」：`web boot: 1 entry did not activate` / `pending (waiting for service: settingsScope)`；
- 唯一的自救按钮是「**禁用第三方插件**」，一点下去 25 个 bundle 全被停用，配置被替换成极简版，事后要手工从备份还原；
- 那个插件之所以拖垮启动，正是因为它自己要求在 boot 时装进 cordis 树。

所以这层保险放在进程之外：它读文件、写文件、杀进程，从不被 DSH 加载，也不会被「禁用第三方插件」一键停掉。

## 它做什么

1. 双击快捷方式 → 立刻拉起 `DeepSeek Harness.exe`（与原生双击等价）
2. 同时以隐藏窗口启动 `watchdog.ps1`
3. 看门狗等 20 秒，比对 `%APPDATA%\@deepseek-ai\dsh-desktop\logs` 里的 `crash-*.log`：
   - **没有新日志** → 把当前 5 个配置文件存成 `last-good`，退出
   - **有新日志** → 杀进程 → 从 `last-good` 拷回 5 个文件 → 重启 → 弹窗告知

判据只看崩溃日志，**不看进程存活**：`web boot` 失败时进程是活得好好的，只有日志是新的。

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
| `start-dsh.vbs` | 双击入口。先起 exe，再隐藏起看门狗 |
| `watchdog.ps1` | 快照、判定、回滚 |
| `config.ini` | 由 install.ps1 生成，可手改 |

快照目录：`%USERPROFILE%\.dsh\boot-snapshots\`（`last-good\` 一份 + 最多 5 份 `pre-boot-*\`，合计约 1 MB）
日志目录：`logs\`（每次启动一份 `watchdog-<时间戳>.log`）

## 边界（老实说）

- **只救配置层**：插件/配置把启动弄坏这一类。exe 损坏、asar 被覆盖、磁盘满、端口被占——回滚配置没用，但它会在日志里写清楚。
- **只在那 20 秒窗口里看一次**：运行中闪退、用一半 OOM 崩溃，它不知道。
- **只认崩溃日志**：如果某种失败模式不写 `crash-*.log`，它会误判为健康。
- **进程数为 0 时不刷新 `last-good`**：没被真正跑通的配置不允许被认证成"好"，否则坏配置会污染回滚源。
- **只在从该快捷方式启动时生效**：从开始菜单或命令行启动 DSH 不会有保护。

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

## 许可

MIT
