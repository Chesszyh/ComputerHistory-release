# 开发与测试

使用 macOS 和 Swift 6。核心逻辑位于 `Sources/ComputerHistoryCore`；命令行和菜单栏是独立可执行目标。Swift Package Manager 清单见 `Package.swift`。

```bash
swift test
swift build -c release
python3 scripts/test-process-control.py .build/debug/computer-history
python3 scripts/test-process-control.py .build/release/computer-history
```

进程测试须以普通用户运行，权限拒绝场景不支持 root。测试拥有自己的临时目录和子进程，不应修改真实运行服务。常规测试不访问个人历史；只有显式设置 `COMPUTER_HISTORY_SAMPLES` 才启用三项私有样本兼容性测试，其断言针对维护者的数据集，不适用于任意小样本。

修复生命周期问题时增加跨状态回归：暂停和恢复、应用切换、同窗重启、配置不完整、删除失败与进程身份变化。纯渲染和解析改动使用合成输入即可。模型相关测试应使用本地模拟接口，不能依赖真实密钥或产生付费请求。

文档只描述可由实现和测试支撑的行为；权限与应用兼容性请注明验证环境。注释说明非显然的原因，提交说明最终行为。不要提交真实活动数据、凭据、构建产物或个人机器配置。

提交变更时附问题复现、最终行为与实际执行的验证。涉及公开 API 或配置行为变化时同步更新相关文档。
