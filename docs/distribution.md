# 下载、安装和升级

从 [GitHub Releases](https://github.com/Chesszyh/ComputerHistory-release/releases/latest) 下载 Apple Silicon（`arm64`）压缩包，适用于 macOS 13 或更高版本。源码构建入口见[项目说明](https://github.com/Chesszyh/ComputerHistory-release#readme)。

## 安装

解压包包含两个程序、安装管理脚本和许可证。安装器需要 Python 3（`python3 --version` 可检查）；程序本身不需要 Python 或 Swift 工具链。在解压目录打开终端执行：

```bash
python3 manage-install.py install
~/Applications/ComputerHistory/computer-history --check
```

程序固定安装到 `~/Applications/ComputerHistory`，无需管理员权限。安装器保留已有登录启动设置，更新其实际路径；首次安装不会自动启用登录启动，也不自动开启采集。在菜单栏设置中可以启用登录启动，该登录项只启动菜单栏。

下载包由发布构建进行临时签名，尚未使用 Developer ID 签名或 Apple 公证。本机源码构建可使用自己的持久签名身份，它不能替代面向其他用户的 Developer ID。macOS 首次运行可能阻止两个程序；确认来源后，按照[Apple 的逐程序打开流程](https://support.apple.com/102445)在“系统设置 → 隐私与安全性”选择“仍要打开”，再重试。安装器不关闭 Gatekeeper，也不移除下载隔离属性；若复制或执行被系统拒绝，安装会报错。

在“系统设置 → 隐私与安全性”中配置：

- **辅助功能**：读取应用界面，监听及归属交互。授权对象受启动方式和系统版本影响，可能是程序本身或启动它的终端。
- **输入监控**：键盘和鼠标监听可能需要，须结合采集日志和实际短时采集确认。
- **屏幕录制**：仅显式启用本地窗口文字识别时需要；普通辅助功能采集不依赖它。识别行为与配置见[采集说明](https://github.com/Chesszyh/ComputerHistory-release/blob/main/docs/collector.md#采集行为与局限)。

`--check` 只检查辅助功能状态，不能证明其他权限或应用兼容性。可先进行一次十五秒本地采集，查看结果和 `~/.computer-history/collector.log`：

```bash
~/Applications/ComputerHistory/computer-history collect --seconds 15
~/Applications/ComputerHistory/computer-history --status
```

开始后台采集及本地事实摘要，禁止模型调用：

```bash
~/Applications/ComputerHistory/computer-history supervise --daemon --no-model
~/Applications/ComputerHistory/computer-history-menubar >/dev/null 2>&1 &
```

模型配置及外发边界见[隐私说明](https://github.com/Chesszyh/ComputerHistory-release/blob/main/docs/privacy.md)。菜单栏与命令行应保持在同一目录，菜单栏按相邻路径寻找命令行程序。

## 升级

下载并解压新包，在新解压目录再次执行 `python3 manage-install.py install`。安装器先验证新程序签名与启动，卸载已加载的菜单栏登录项，使用身份校验停止旧菜单栏及采集器，并等待监督、生成等 ComputerHistory 进程退出。无法停止或仍有其他实例时会中止，不替换程序。安装目录含非安装器管理的文件时也会中止。

新文件先复制到同一磁盘的暂存目录，再切换目录；失败时恢复旧程序与原登录项文件。登录项加载失败会报告错误；旧登录项恢复也失败时需在菜单栏重新启用。安装期间不要从其他终端启动旧版本。回退不自动恢复采集。

升级保留 `~/.computer-history` 中的历史、配置和请求记录，也不改动钥匙串凭据。原来从版本化解压目录启动的实例可以迁移到固定路径；未登记身份的老版本须先从界面退出。自定义数据目录需传 `--out /你的数据目录`；其他目录中的实例也应先停止。

升级后按以下顺序验证：

1. 执行固定安装目录中的 `computer-history --check`，确认系统权限；更换签名或程序位置后可能需要重新授权。
2. 如原来启用了登录启动，检查 `~/Library/LaunchAgents/xyz.chesszyh.computerhistory.menubar.plist` 的 `ProgramArguments` 指向固定安装目录，并用 `launchctl print gui/$(id -u)/xyz.chesszyh.computerhistory.menubar` 检查加载状态。
3. 按升级前使用的命令和参数重新启动采集，执行 `--status` 并检查日志、最新事件段和菜单栏。安装器不会猜测原来的模型开关或自定义参数。

## 卸载

```bash
python3 ~/Applications/ComputerHistory/manage-install.py uninstall
```

卸载会停止进程、移除本安装器管理的程序目录和菜单栏登录项，默认保留数据及钥匙串凭据。若需要彻底清理，请先在模型设置移除已保存的密钥；卸载后再单独删除你明确选定的数据目录（默认 `~/.computer-history`）。这会永久删除其中的历史、配置和请求记录。旧版本解压目录由使用者自行移除。
