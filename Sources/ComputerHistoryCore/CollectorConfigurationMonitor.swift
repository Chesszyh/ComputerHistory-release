import Foundation

public struct CollectorConfigurationMonitor {
    private let url: URL
    private var lastData: Data?

    public init(root: URL) {
        url = CollectorConfig.fileURL(rootDirectory: root)
        lastData = try? Data(contentsOf: url)
    }

    public mutating func poll() throws -> CollectorConfig? {
        let data = try Data(contentsOf: url)
        guard data != lastData else { return nil }
        lastData = data
        return try CollectorConfig.decode(from: data)
    }
}
