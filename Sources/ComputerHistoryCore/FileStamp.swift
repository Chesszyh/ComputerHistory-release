import Foundation
import Darwin

struct FileStamp: Equatable, Sendable {
    var size: UInt64
    var modified: Date
    var inode: UInt64

    init?(_ url: URL) {
        var value = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &value)
        }
        guard result == 0 else { return nil }
        size = UInt64(max(0, value.st_size))
        modified = Date(timeIntervalSince1970: Double(value.st_mtimespec.tv_sec)
            + Double(value.st_mtimespec.tv_nsec) / 1_000_000_000)
        inode = UInt64(value.st_ino)
    }
}
