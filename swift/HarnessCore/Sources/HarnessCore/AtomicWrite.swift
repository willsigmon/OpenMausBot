import Foundation

/// Durable, atomic file replace — the port of server/atomic.ts.
///
/// A reader must always see either the complete old contents or the complete
/// new ones; without this an interrupted write leaves half-written JSON that
/// fails to parse on next boot and is silently treated as empty state.
public enum AtomicWriteError: Error {
    case writeFailed(underlying: any Error)
}

public enum AtomicWrite {
    /// Write `data`, fsync it, then rename over `path`. Permissions are set
    /// on the temporary inode itself so the final rename preserves them and
    /// no broader-permission file is ever visible at `path`.
    public static func writeFile(_ path: String, data: Data, mode: mode_t = 0o600) throws {
        let tmp = "\(path).\(getpid()).\(UUID().uuidString.lowercased()).tmp"
        do {
            try data.write(to: URL(fileURLWithPath: tmp), options: [.atomic])
            // .atomic writes via a temp+rename of its own with default
            // permissions, so set the sensitive-file bits explicitly on this
            // inode before the rename makes it visible at the target path.
            if chmod(tmp, mode) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try syncFile(atPath: tmp)
            if rename(tmp, path) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? FileManager.default.removeItem(atPath: tmp)
            throw AtomicWriteError.writeFailed(underlying: error)
        }
    }

    public static func writeString(_ path: String, _ string: String, mode: mode_t = 0o600) throws {
        try writeFile(path, data: Data(string.utf8), mode: mode)
    }
}

private func syncFile(atPath path: String) throws {
    let fd = open(path, O_RDONLY)
    guard fd >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { close(fd) }
    if fsync(fd) != 0 {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
