import Foundation

// PATH augmentation for GUI launches — the direct port of server/env-path.ts.
//
// A macOS app launched from Finder inherits a bare PATH (/usr/bin:/bin:…):
// no ~/.local/bin (the claude installer default), no /opt/homebrew/bin, and
// no nvm/volta/asdf shims — those only exist in interactive shells. The
// terminal sees the CLIs; the packaged app doesn't. So every spawn of an
// agent CLI goes through EnvPath.augmentedPath(): the inherited PATH, plus
// the well-known install locations that exist on this machine, plus (async,
// best-effort) whatever PATH the user's real login shell reports.
//
// The win32 branches die entirely per the port plan.

/// nvm keeps every node version's bin dir separately; newest first so a CLI
/// installed under the latest node wins.
private func nvmBinDirs() -> [String] {
    let base = DataDirs.homeJoin(".nvm", "versions", "node")
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: base) else { return [] }
    return entries
        .filter { $0.hasPrefix("v") }
        .sorted(by: { (lhs: String, rhs: String) -> Bool in
            // numeric-aware compare, newest first ("v22" > "v9")
            lhs.compare(rhs, options: .numeric) == .orderedDescending
        })
        .map { DataDirs.join(DataDirs.join(base, $0), "bin") }
}

func envPathKnownDirs() -> [String] {
    [
        DataDirs.homeJoin(".local", "bin"),      // claude installer default
        DataDirs.homeJoin(".npm-global", "bin"), // npm prefix ~/.npm-global (claude, opencode)
        DataDirs.homeJoin(".kimi-code", "bin"),  // kimi-code installer
        DataDirs.homeJoin(".grok", "bin"),       // x.ai installer
        DataDirs.homeJoin(".opencode", "bin"),   // opencode installer
        DataDirs.homeJoin(".claude", "local"),   // claude "local install"
        "/opt/homebrew/bin",                     // brew, Apple silicon
        "/usr/local/bin",                        // brew Intel / classic installs
        DataDirs.homeJoin(".volta", "bin"),
        DataDirs.homeJoin(".bun", "bin"),
        DataDirs.homeJoin(".asdf", "shims"),
        DataDirs.homeJoin(".deno", "bin"),
        DataDirs.homeJoin("bin"),
    ] + nvmBinDirs()
}

public enum EnvPath {
    private static let lock = NSLock()

    // Memoized state. The login-shell probe writes from a background task,
    // so these are confined behind `lock` (or read only under it).
    private nonisolated(unsafe) static var cached: String?
    private nonisolated(unsafe) static var probed = false
    private nonisolated(unsafe) static var loginShellPath: String?

    /// Drop the memoized PATH so the next augmentedPath() rescans. Called
    /// when the app re-probes engines, so "check again" can find something
    /// installed since launch. `probed` must reset too, or a rescan would
    /// rebuild the cache without rc-file entries and never re-probe —
    /// "check again" would permanently lose anything only the login shell's
    /// rc file knows about.
    public static func resetPathCache() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
        probed = false
    }

    /// Test hook — the cache is process-wide otherwise.
    public static func resetPathCacheForTests() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
        probed = false
        loginShellPath = nil
    }

    /// Current best PATH, synchronously. Cheap after the first call.
    public static func augmentedPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        lock.lock()
        defer { lock.unlock() }
        if cached == nil {
            var parts: [String] = []
            if let extra = environment["OMB_EXTRA_PATH"] {
                parts += splitPathList(extra)
            }
            if let inherited = environment["PATH"] {
                parts += splitPathList(inherited)
            }
            // Keep the last successful login-shell result while a rescan
            // starts a fresh asynchronous probe; otherwise resetPathCache()
            // would make rc-only CLIs disappear again for the response that
            // triggered it.
            if let shellPath = loginShellPath {
                parts += splitPathList(shellPath)
            }
            parts += knownDirsThatExist()
            cached = mergePaths(parts)
        }
        // belt-and-braces: fold in the login shell's PATH once, in the
        // background — catches anything the known-dirs list doesn't (custom
        // rc exports). Never blocks a spawn; the next one benefits.
        if !probed {
            probed = true
            probeLoginShellPath()
        }
        return cached ?? ""
    }

    static func knownDirsThatExist() -> [String] {
        envPathKnownDirs().filter { FileManager.default.fileExists(atPath: $0) }
    }

    static func mergePaths(_ parts: [String]) -> String {
        var seen = Set<String>()
        var unique: [String] = []
        for part in parts where !part.isEmpty && !seen.contains(part) {
            seen.insert(part)
            unique.append(part)
        }
        return unique.joined(separator: ":")
    }

    static func splitPathList(_ value: String) -> [String] {
        value.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
    }

    /// Probe `$SHELL -l -i -c` for the user's real PATH in the background.
    /// nvm and friends live in .zshrc/.bashrc, which only interactive shells
    /// read; a marker isolates $PATH from any rc-file noise.
    private static func probeLoginShellPath() {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", #"printf "__OMB_PATH__%s" "$PATH""#]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8),
                  let range = text.range(of: #"__OMB_PATH__([^\n]*)"#, options: .regularExpression),
                  !text[range].isEmpty
            else { return }
            // strip the marker itself
            let found = String(text[range].dropFirst("__OMB_PATH__".count))
            guard !found.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }
            loginShellPath = found
            cached = mergePaths(splitPathList(cached ?? "") + splitPathList(found))
        }
    }

    /// Every `name` binary on the given PATH (default: the augmented PATH)
    /// as absolute paths, in PATH order (first = what a bare name would
    /// run). Used by the Engines panel's "detected" dropdown and the
    /// cli-candidates endpoint. A path-ish name is echoed back as-is — it
    /// already IS a location.
    public static func findCliCandidates(
        name: String,
        pathOverride: String? = nil
    ) -> [String] {
        if name.isEmpty || name.contains("\n") || name.contains("\r") { return [] }
        if name.contains("/") || name.contains("\\") || name.firstMatch(of: /^[a-zA-Z]:/) != nil {
            return [name]
        }
        var out: [String] = []
        for dir in splitPathList(pathOverride ?? augmentedPath()) {
            if dir.isEmpty { continue }
            let p = DataDirs.join(dir, name)
            if FileManager.default.fileExists(atPath: p) {
                out.append(p)
            }
        }
        return out
    }

    // ── cli-string splitting ───────────────────────────────────────────────

    public struct ResolvedSpawn: Sendable, Equatable {
        public var command: String
        public var args: [String]

        public init(command: String, args: [String]) {
            self.command = command
            self.args = args
        }
    }

    /// Split a `cli` string into [command, ...fixedArgs] on unquoted
    /// whitespace — a mini tokenizer, never a shell. Quotes group segments
    /// (paths with spaces, fixed args with spaces); no escapes, no
    /// substitution, nothing evaluated.
    public static func splitCliString(_ cli: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quote: Character? = nil
        for ch in cli.trimmingCharacters(in: .whitespacesAndNewlines) {
            if let openQuote = quote {
                if ch == openQuote {
                    quote = nil
                } else {
                    current.append(ch)
                }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch.isWhitespace {
                if !current.isEmpty {
                    out.append(current)
                }
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty {
            out.append(current)
        }
        return out
    }

    /// How to actually spawn `cli` with `args`. Identity on POSIX — it
    /// already resolves PATH and #! itself.
    public static func resolveCliSpawn(cli: String, args: [String]) -> ResolvedSpawn {
        ResolvedSpawn(command: cli, args: args)
    }
}
