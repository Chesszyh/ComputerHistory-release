import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ComputerHistoryCore

struct ReportsPane: View {
    @ObservedObject var model: StatusModel
    @State private var exportMaterial = false
    @State private var exportFormat = "md"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                PanelBackButton(action: { model.showsReports = false })
                    .accessibilityIdentifier("reports-back")
                Spacer()
                Text("日报、周报与导出").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { model.loadReports() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(model.reportBusy)
            }
            Divider()
            HStack {
                Picker("报告", selection: Binding(get: { model.reportKind }, set: { model.reportKind = $0; model.loadReports() })) {
                    ForEach(ReportKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }.labelsHidden().pickerStyle(.segmented)
                DatePicker("日期", selection: Binding(get: { model.reportDate }, set: { model.reportDate = $0; model.loadReports() }), in: ...Date(), displayedComponents: .date)
                    .labelsHidden()
            }
            .disabled(model.reportBusy)
            HStack {
                Button(model.reportText.isEmpty ? "生成报告" : "重新生成") { model.generateReport() }
                    .disabled(model.reportBusy || model.reportMaterial.isEmpty)
                    .accessibilityIdentifier("report-generate")
                Button("复制报告") { model.copyReport(material: false) }
                    .disabled(model.reportText.isEmpty || model.reportBusy)
                    .accessibilityIdentifier("report-copy")
                Spacer()
                if model.reportBusy { ProgressView().controlSize(.small) }
            }.controlSize(.small)
            ScrollView {
                if model.reportText.isEmpty {
                    Text("尚无报告。可直接复制活动材料，或生成报告。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                } else {
                    ReportDocument(text: model.reportText).textSelection(.enabled).padding(8)
                }
            }
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Button("复制给 AI 的材料") { model.copyReport(material: true) }
                .disabled(model.reportMaterial.isEmpty || model.reportBusy)
                .accessibilityIdentifier("report-copy-material")
            HStack {
                Picker("导出", selection: $exportMaterial) {
                    Text("报告").tag(false); Text("活动材料").tag(true)
                }.labelsHidden()
                Picker("格式", selection: $exportFormat) { Text("Markdown").tag("md"); Text("TXT").tag("txt") }
                    .labelsHidden()
                Button("导出…", action: save)
                    .disabled(model.reportBusy || (exportMaterial ? model.reportMaterial.isEmpty : model.reportText.isEmpty))
            }.controlSize(.small)
            if let error = model.reportError {
                ScrollView { Text(error).foregroundStyle(.red).textSelection(.enabled) }.frame(maxHeight: 65)
            } else if let message = model.reportMessage {
                Text(message).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
        .padding(14)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [exportFormat == "txt" ? .plainText : UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = ReportPeriod(kind: model.reportKind, date: model.reportDate).id + (exportMaterial ? "-material" : "") + "." + exportFormat
        if panel.runModal() == .OK, let url = panel.url { model.saveReport(to: url, material: exportMaterial) }
    }
}

struct ReportDocument: View {
    let text: String
    private var sections: [(heading: String, content: String)] {
        var result: [(String, String)] = []
        var heading = "报告"; var content: [String] = []
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("# ") || line.hasPrefix("## ") || line.hasPrefix("### ") {
                if !content.isEmpty { result.append((heading, content.joined(separator: "\n"))) }
                heading = String(line.drop(while: { $0 == "#" || $0 == " " })); content = []
            } else { content.append(line) }
        }
        if !content.isEmpty { result.append((heading, content.joined(separator: "\n"))) }
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                SectionBlock(heading: section.heading, content: section.content)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
