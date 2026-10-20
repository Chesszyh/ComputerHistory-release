import Foundation

public struct ActivityWatchEvidence: Codable, Sendable, Equatable {
    public var startedAt: Date
    public var endedAt: Date
    public var status: String?
    public var windowBucket: String
    public var windowEventID: Int
    public var afkBucket: String?
    public var afkEventID: Int?
}

public struct ActivityWatchSnapshot: Sendable {
    public var application: String
    public var title: String?
    public var url: String?
    public var evidence: ActivityWatchEvidence
}

/// Reads the local watcher's most recent state; never writes to ActivityWatch.
public struct ActivityWatchClient: Sendable {
    private let baseURL: URL
    private let session: URLSession
    public init(baseURL: URL = URL(string: "http://127.0.0.1:5600")!, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }
    private struct Info: Decodable { var hostname: String }
    private struct Bucket: Decodable { var type: String; var hostname: String }
    private struct Event: Decodable {
        var id: Int
        var timestamp: String
        var duration: Double
        struct Payload: Decodable { var app: String?; var title: String?; var url: String?; var status: String? }
        var data: Payload
        var start: Date? {
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return parser.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp)
        }
        var end: Date? { start?.addingTimeInterval(duration) }
    }
    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/0/" + path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 3
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    public func snapshot(now: Date = Date()) async throws -> ActivityWatchSnapshot? {
        let info: Info = try await get("info")
        let buckets: [String: Bucket] = try await get("buckets/")
        let local = buckets.filter { $0.value.hostname == info.hostname }
        guard let windowID = local.keys.sorted().first(where: { local[$0]?.type == "currentwindow" }) else { return nil }
        let windows: [Event] = try await get("buckets/\(windowID)/events", query: [.init(name: "limit", value: "1")])
        guard let window = windows.first, let start = window.start, let end = window.end,
              window.duration.isFinite, window.duration >= 0, end <= now.addingTimeInterval(5),
              now.timeIntervalSince(end) <= 30, let app = window.data.app, !app.isEmpty else { return nil }
        var evidence = ActivityWatchEvidence(startedAt: start, endedAt: min(end, now), status: nil,
            windowBucket: windowID, windowEventID: window.id)
        if let afkID = local.keys.sorted().first(where: { local[$0]?.type == "afkstatus" }) {
            let events: [Event] = try await get("buckets/\(afkID)/events", query: [.init(name: "limit", value: "1")])
            if let afk = events.first, let afkStart = afk.start, let afkEnd = afk.end,
               afk.duration.isFinite, afk.duration >= 0, afkStart <= evidence.endedAt,
               afkEnd >= evidence.endedAt.addingTimeInterval(-15),
               ["afk", "not-afk"].contains(afk.data.status ?? "") {
                evidence.startedAt = max(start, afkStart)
                evidence.status = afk.data.status
                evidence.afkBucket = afkID
                evidence.afkEventID = afk.id
            }
        }
        return ActivityWatchSnapshot(application: app, title: window.data.title, url: window.data.url, evidence: evidence)
    }
}

@MainActor public final class ActivityWatchSampler {
    private var task: Task<Void, Never>?
    private var nextRead = Date.distantPast
    private var enabled = false
    private var lastError: String?
    public init() {}
    public func update(enabled: Bool, now: Date = Date(),
                       read: @escaping @Sendable () async throws -> ActivityWatchSnapshot? = { try await ActivityWatchClient().snapshot() },
                       accept: @escaping (ActivityWatchSnapshot) -> Void) {
        if !enabled {
            task?.cancel(); task = nil
            self.enabled = false; nextRead = .distantPast
            return
        }
        self.enabled = true
        guard task == nil, now >= nextRead else { return }
        nextRead = now.addingTimeInterval(15)
        task = Task { [weak self] in
            do {
                let snapshot = try await read()
                guard !Task.isCancelled, let self, self.enabled else { return }
                self.lastError = nil
                if let snapshot { accept(snapshot) }
            } catch {
                guard !Task.isCancelled, let self else { return }
                let message = "ActivityWatch 读取失败（127.0.0.1:5600）：\(error.localizedDescription)"
                if self.lastError != message { FileHandle.standardError.write(Data((message + "\n").utf8)) }
                self.lastError = message
            }
            self?.task = nil
        }
    }
}
