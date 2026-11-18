import Foundation
import Darwin
import CryptoKit

enum ModelBudgetIndex {
    struct Totals: Equatable {
        var daily: Double = 0
        var monthly: Double = 0
    }

    private struct Fingerprint: Codable, Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init?(_ file: URL) {
            var info = stat()
            guard stat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
            device = info.st_dev
            inode = info.st_ino
            size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
            // In-place edits can restore mtime and keep the original file length.
            changedSeconds = info.st_ctimespec.tv_sec
            changedNanoseconds = info.st_ctimespec.tv_nsec
        }
    }

    private struct Charge: Codable {
        struct Pricing: Codable { let currency: String }
        let startedAt: Date
        let pricing: Pricing?
        let estimatedCost: Double?
    }

    private struct Entry: Codable {
        let fingerprint: Fingerprint
        let charge: Charge
    }

    static func fileURL(root: URL) -> URL {
        ModelRequest.ledgerDirectory(root: root).appendingPathComponent(".budget-index-v1")
    }

    static func totals(root: URL, currency: String, at started: Date,
                       calendar: Calendar = .current) throws -> Totals {
        try ModelRequest.withLedgerLock(root: root) {
            let dir = ModelRequest.ledgerDirectory(root: root)
            let files: [(name: String, url: URL)]
            do {
                files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "json" }
                    .map { (name: $0.lastPathComponent, url: $0) }
                    .sorted { $0.name < $1.name }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return Totals()
            } catch {
                throw ModelSettings.SettingsError.invalid("无法核对总结预算，请检查请求台账目录 requests/。")
            }

            let indexURL = fileURL(root: root)
            let cached = load(at: indexURL)
            let decoder = EventStreamJSON.makeDecoder(acceptingLegacyNumericDates: true)
            var entries = cached ?? [:]
            var changed = cached?.count != files.count
            var totals = Totals()
            let day = calendar.dateInterval(of: .day, for: started)
            let month = calendar.dateInterval(of: .month, for: started)
            for (name, file) in files {
                guard let fingerprint = Fingerprint(file) else { throw ledgerError(file) }
                let entry: Entry
                if let existing = entries[name], existing.fingerprint == fingerprint {
                    entry = existing
                } else {
                    do {
                        let charge = try autoreleasepool {
                            try decoder.decode(Charge.self, from: Data(contentsOf: file))
                        }
                        guard Fingerprint(file) == fingerprint else { throw ledgerError(file) }
                        entry = Entry(fingerprint: fingerprint, charge: charge)
                        entries[name] = entry
                        changed = true
                    } catch { throw ledgerError(file) }
                }
                guard entry.charge.pricing?.currency == currency,
                      let amount = entry.charge.estimatedCost else { continue }
                let date = entry.charge.startedAt
                if let day, date >= day.start, date < day.end { totals.daily += amount }
                if let month, date >= month.start, date < month.end { totals.monthly += amount }
            }
            if changed {
                if entries.count > files.count {
                    let names = Set(files.map(\.name))
                    entries = entries.filter { names.contains($0.key) }
                }
                // The verified totals are usable even when persistence of the derived cache fails.
                try? save(entries, at: indexURL)
            }
            return totals
        }
    }

    private static func load(at url: URL) -> [String: Entry]? {
        guard let data = try? Data(contentsOf: url), data.count >= SHA256.Digest.byteCount else { return nil }
        let payload = data.dropFirst(SHA256.Digest.byteCount)
        // A small integrity check avoids re-reading ledger bodies to verify otherwise decodable amounts.
        guard data.prefix(SHA256.Digest.byteCount).elementsEqual(SHA256.hash(data: payload)) else { return nil }
        return try? JSONDecoder().decode([String: Entry].self, from: payload)
    }

    private static func save(_ entries: [String: Entry], at url: URL) throws {
        let payload = try JSONEncoder().encode(entries)
        var data = Data(SHA256.hash(data: payload))
        data.append(payload)
        try data.write(to: url, options: .atomic)
    }

    private static func ledgerError(_ file: URL) -> ModelSettings.SettingsError {
        .invalid("无法核对总结预算，请检查请求台账文件 \(file.lastPathComponent)。")
    }
}
