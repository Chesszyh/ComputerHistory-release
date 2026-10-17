import AppKit
import ScreenCaptureKit
import Vision

public enum WindowTextReader {
    public struct Result: Sendable {
        public var text: String
        public var windowID: UInt32
        public init(text: String, windowID: UInt32) { self.text = text; self.windowID = windowID }
    }

    public enum ReadError: Error, CustomStringConvertible {
        case permission, systemVersion
        public var description: String {
            switch self {
            case .permission: return "缺少屏幕录制权限，请在系统设置中授权采集程序后重启。"
            case .systemVersion: return "窗口文字识别需要 macOS 14 或更高版本。"
            }
        }
    }

    public static func read(pid: Int32, windowID: UInt32?,
                            isAllowed: @Sendable () async -> Bool = { true }) async throws -> Result? {
        guard await isAllowed() else { return nil }
        await MainActor.run { _ = NSApplication.shared }
        guard #available(macOS 14, *) else { throw ReadError.systemVersion }
        guard CGPreflightScreenCaptureAccess() else { throw ReadError.permission }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let windows = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0
                && $0.frame.width >= 200 && $0.frame.height >= 150
        }
        let selected: SCWindow?
        if let windowID { selected = windows.first { $0.windowID == windowID } }
        else { selected = windows.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height } }
        guard let window = selected else { return nil }
        let configuration = SCStreamConfiguration()
        configuration.width = min(2400, Int(window.frame.width * 2))
        configuration.height = Int(Double(configuration.width) * window.frame.height / window.frame.width)
        configuration.showsCursor = false
        guard await isAllowed() else { return nil }
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
        try Task.checkCancellation()
        guard await isAllowed() else { return nil }
        let text = try await Task.detached(priority: .utility) { try recognize(image) }.value
        return Result(text: text, windowID: window.windowID)
    }

    static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "ja-JP", "en-US"]
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return String((request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n").prefix(12000))
    }
}

/// 读取在后台执行；取消后的结果不能写入已经切换或暂停的采集上下文。
@MainActor public final class WindowTextSampler {
    public typealias Read = @Sendable (Int32, UInt32?) async throws -> WindowTextReader.Result?
    private var task: Task<Void, Never>?
    private var context: CollectionSession.WindowTextContext?
    private var nextRead = Date.distantPast
    private var lastError: String?

    public init() {}

    public func update(_ candidate: CollectionSession.WindowTextContext?, now: Date = Date(),
                       read: @escaping Read = { try await WindowTextReader.read(pid: $0, windowID: $1) },
                       accept: @escaping (CollectionSession.WindowTextContext, WindowTextReader.Result) -> Void) {
        if candidate != context {
            task?.cancel(); task = nil
            context = candidate
            nextRead = .distantPast
        }
        guard let candidate, let pid = candidate.app.processIdentifier,
              task == nil, now >= nextRead else { return }
        nextRead = now.addingTimeInterval(30)
        task = Task { [weak self] in
            do {
                let result = try await read(pid, candidate.window?.windowID)
                guard !Task.isCancelled, let self, self.context == candidate else { return }
                self.lastError = nil
                if let result { accept(candidate, result) }
            } catch {
                guard !Task.isCancelled, let self, self.context == candidate else { return }
                let message = "窗口文字识别失败：\(error)"
                if message != self.lastError { FileHandle.standardError.write(Data((message + "\n").utf8)) }
                self.lastError = message
            }
            if let self, self.context == candidate {
                self.task = nil
                self.nextRead = Date().addingTimeInterval(30)
            }
        }
    }
}
