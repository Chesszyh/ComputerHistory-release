# 下载与运行

从 [Releases](https://github.com/Chesszyh/ComputerHistory-release/releases/latest) 下载 Apple Silicon（`arm64`）压缩包。运行环境为 macOS 13 或更高版本。解压后包含命令行程序、菜单栏程序和许可证，无需安装 Swift 工具链。

在解压目录打开终端，先检查权限：

```bash
./computer-history --check
```

在“系统设置 → 隐私与安全性”中检查辅助功能和输入监控权限。下载包使用本地临时签名，尚未进行 Developer ID 签名和 Apple 公证；如系统阻止运行，可在同一设置页为已确认来源的程序选择“仍要打开”。

开始本地采集及事实摘要，不调用模型：

```bash
./computer-history supervise --daemon --no-model
./computer-history-menubar >/dev/null 2>&1 &
```

默认数据目录为 `~/.computer-history`。查看状态或停止程序：

```bash
./computer-history --status
./computer-history --stop
./computer-history-menubar --stop
```

保持解压目录位置稳定；登录启动项会引用程序的实际路径。升级前停止旧采集器和菜单栏，再使用新版本启动。模型配置、采集策略及源码构建见[项目说明](https://github.com/Chesszyh/ComputerHistory-release#readme)，数据保存与外发边界见[隐私说明](https://github.com/Chesszyh/ComputerHistory-release/blob/main/docs/privacy.md)。
