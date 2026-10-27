import SwiftUI
import ComputerHistoryCore

struct PermissionSetupPane: View {
    @ObservedObject var model: StatusModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("欢迎使用 ComputerHistory").font(.title2.weight(.semibold))
                    Text("允许记录应用界面和操作后，即可开始本地活动记录。")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    permission("辅助功能", detail: "读取应用界面与交互对象", granted: model.permissionStatus?.accessibility, kind: "accessibility")
                    permission("输入监控", detail: "记录键盘、点击与滚动操作", granted: model.permissionStatus?.inputMonitoring, kind: "input")
                    permission("屏幕录制", detail: "仅在启用窗口文字识别时需要", granted: model.permissionStatus?.screenRecording, kind: "screen")
                    Divider()
                    HStack {
                        Text("模型密钥").font(.headline)
                        Spacer()
                        Button("恢复密钥访问") { model.restoreCredentialAccess() }
                            .accessibilityIdentifier("restore-credential-access")
                    }
                    Text("仅在配置模型时使用系统钥匙串。首次恢复时，请在系统验证中选择“始终允许”。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let message = model.permissionMessage {
                        Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                    if let listener = model.status.inputListening {
                        Text("后台采集器：" + listener.label).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("重新检查") { model.refreshPermissions() }
                if !model.status.process.running {
                    Button("开始记录") { model.startCollectorFromSetup() }
                        .disabled(model.permissionStatus?.accessibility != true || model.permissionStatus?.inputMonitoring != true)
                        .accessibilityIdentifier("setup-start-collector")
                }
                Spacer()
                Button("完成") { model.finishPermissionSetup() }.buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("permission-setup-done")
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .disabled(model.permissionBusy)
        .onAppear { model.refreshPermissions() }
    }
    private func permission(_ title: String, detail: String, granted: Bool?, kind: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(granted.map { $0 ? "已授权" : "未授权" } ?? "检查中").font(.caption).foregroundStyle(.secondary)
                .fixedSize()
            Button("前往授权") { model.refreshPermissions(request: kind) }
                .fixedSize()
                .accessibilityIdentifier("permission-" + kind)
        }
    }
}
