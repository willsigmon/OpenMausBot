import Foundation

/// Data-dir layout — the port of the path half of server/config.ts
/// (`DATA_DIR`, `EVENTS_DIR`, `NATIVE_DIR`, `ensureDirs`).
///
/// `OMB_DATA_DIR` isolates test/soak rigs from the user's real fleet; when
/// unset the home is `~/.openmausbot`, matching upstream byte-for-byte.
///
/// Upstream reads `process.env.OMB_DATA_DIR` once at module load. A Swift
/// package cannot freeze process env at import time without fighting test
/// isolation, so resolution happens per call against a process-wide snapshot
/// that `DataDirs.reloadEnvironment()` refreshes. Tests set `OMB_DATA_DIR`
/// and call `reloadEnvironment()` instead of mutating global state blindly.
public enum DataDirs {
    /// One-time migration from the pre-rename data dir — bots, transcripts,
    /// config and keys all carry over.
    static let legacyDirName = ".openglobot"

    private static let lock = NSLock()
    private nonisolated(unsafe) static var cachedDataDirOverride: String? = ProcessInfo.processInfo.environment["OMB_DATA_DIR"]

    /// Re-read `OMB_DATA_DIR`. Called by tests after setting the variable.
    public static func reloadEnvironment() {
        lock.lock()
        defer { lock.unlock() }
        cachedDataDirOverride = ProcessInfo.processInfo.environment["OMB_DATA_DIR"]
    }

    /// The resolved data directory: `$OMB_DATA_DIR` when set, else
    /// `~/.openmausbot`.
    public static var dataDir: String {
        lock.lock()
        let override = cachedDataDirOverride
        lock.unlock()
        if let override, !override.isEmpty { return override }
        return homeJoin(".openmausbot")
    }

    /// Canonical per-thread NDJSON event logs.
    public static var eventsDir: String { join(dataDir, "events") }

    /// Verbatim native protocol tees.
    public static var nativeDir: String { join(dataDir, "native") }

    /// Path of the persisted app configuration file.
    public static var configFile: String { join(dataDir, "config.json") }

    /// Create the data dir tree, migrating the legacy directory first.
    /// Cross-device or busy rename falls through to a fresh dir, exactly like
    /// upstream's try/renameSync/catch.
    @discardableResult
    public static func ensureDirs() -> String {
        let target = dataDir
        let fm = FileManager.default
        if !fm.fileExists(atPath: target) {
            let legacy = homeJoin(legacyDirName)
            if fm.fileExists(atPath: legacy) {
                // best effort only; failure means we start fresh
                try? fm.moveItem(atPath: legacy, toPath: target)
            }
        }
        for dir in [target, eventsDir, nativeDir] {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        return target
    }

    // ── path helpers ──────────────────────────────────────────────────────

    static func homeJoin(_ components: String...) -> String {
        // Prefer $HOME like Node's os.homedir(); Foundation's NSHomeDirectory
        // caches its value and can disagree with a freshly-set HOME.
        let home = getenv("HOME").flatMap { String(cString: $0) } ?? NSHomeDirectory()
        var parts = components
        parts.insert(home, at: 0)
        return parts.joined(separator: "/")
    }

    /// POSIX-style join: empty components dropped, absolute right-hand side
    /// replaces the left (matching Node's path.join is NOT this; but every
    /// internal call site joins relative names onto an absolute base).
    static func join(_ base: String, _ component: String) -> String {
        if base.isEmpty { return component }
        if component.isEmpty { return base }
        if component.hasPrefix("/") { return component }
        var prefix = base
        while prefix.hasSuffix("/") { prefix.removeLast() }
        return "\(prefix)/\(component)"
    }
}
