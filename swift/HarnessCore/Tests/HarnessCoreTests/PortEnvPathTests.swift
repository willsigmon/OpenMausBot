import Foundation
import XCTest
@testable import HarnessCore

final class PortEnvPathTests: XCTestCase {
    override func setUp() {
        super.setUp()
        EnvPath.resetPathCacheForTests()
    }

    override func tearDown() {
        EnvPath.resetPathCacheForTests()
        super.tearDown()
    }

    func testAugmentedPathIncludesInheritedPathAndExistingKnownDirs() {
        // Point HOME at a scratch dir so only the dirs we create are found.
        // getenv (not NSHomeDirectory): Foundation caches the home string.
        let originalHome = String(cString: getenv("HOME"))
        let scratchHome = NSTemporaryDirectory() + "port-envpath-home"
        setenv("HOME", scratchHome, 1)
        defer { setenv("HOME", originalHome, 1) }
        try? FileManager.default.createDirectory(
            atPath: DataDirs.join(DataDirs.join(scratchHome, ".claude"), "local"),
            withIntermediateDirectories: true)

        let augmented = EnvPath.augmentedPath(environment: ["PATH": "/usr/bin:/bin:/custom/entry"])
        let parts = augmented.split(separator: ":").map(String.init)
        XCTAssertTrue(parts.contains("/usr/bin"))
        XCTAssertTrue(parts.contains("/bin"))
        XCTAssertTrue(parts.contains("/custom/entry"), "inherited PATH is preserved in order")
        XCTAssertTrue(
            parts.contains(DataDirs.join(DataDirs.join(scratchHome, ".claude"), "local")),
            "existing known dirs are folded in")
        XCTAssertFalse(parts.contains { $0.hasSuffix(".grok/bin") && $0.contains("port-envpath-home") },
                       "nonexistent known dirs are skipped")

        // OMB_EXTRA_PATH leads the list.
        EnvPath.resetPathCacheForTests()
        let withExtra = EnvPath.augmentedPath(environment: [
            "PATH": "/usr/bin",
            "OMB_EXTRA_PATH": "/extra/a:/extra/b",
        ])
        XCTAssertTrue(withExtra.hasPrefix("/extra/a:/extra/b:"), "extra path entries lead the merged PATH")

        // Deduplication.
        EnvPath.resetPathCacheForTests()
        let deduped = EnvPath.augmentedPath(environment: ["PATH": "/usr/bin:/usr/bin"])
        XCTAssertEqual(deduped.split(separator: ":").filter { $0 == "/usr/bin" }.count, 1)
    }

    func testFindCliCandidatesEchoesPathishNamesAndScansPathOrder() throws {
        // Path-ish names come back untouched.
        XCTAssertEqual(EnvPath.findCliCandidates(name: "/usr/bin/true"), ["/usr/bin/true"])
        XCTAssertEqual(EnvPath.findCliCandidates(name: ""), [])
        XCTAssertEqual(EnvPath.findCliCandidates(name: "bad\nname"), [])

        // Create two dirs, each holding `fake-cli`; PATH order decides.
        let root = NSTemporaryDirectory() + "port-candidates-\(UUID().uuidString.lowercased())"
        let dirA = DataDirs.join(root, "a")
        let dirB = DataDirs.join(root, "b")
        try FileManager.default.createDirectory(atPath: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: dirB, withIntermediateDirectories: true)
        for dir in [dirA, dirB] {
            FileManager.default.createFile(atPath: DataDirs.join(dir, "fake-cli"), contents: Data("#!/bin/sh\n".utf8))
        }
        defer { try? FileManager.default.removeItem(atPath: root) }

        let candidates = EnvPath.findCliCandidates(
            name: "fake-cli", pathOverride: "\(dirA):\(dirB)")
        XCTAssertEqual(candidates, [DataDirs.join(dirA, "fake-cli"), DataDirs.join(dirB, "fake-cli")])

        // Nothing on the real augmented PATH matches a fixture-only name.
        XCTAssertTrue(EnvPath.findCliCandidates(name: "fake-cli").isEmpty)
    }

    func testSplitCliStringTokenizesQuotesNotShells() {
        XCTAssertEqual(EnvPath.splitCliString("ag claude agp"), ["ag", "claude", "agp"])
        XCTAssertEqual(EnvPath.splitCliString(#""/Applications/My Tools/claude" --flag"#),
                       ["/Applications/My Tools/claude", "--flag"])
        XCTAssertEqual(EnvPath.splitCliString("'/opt/my tools/cli' run 'two words'"),
                       ["/opt/my tools/cli", "run", "two words"])
        XCTAssertEqual(EnvPath.splitCliString("   spaced   out  "), ["spaced", "out"])
        XCTAssertEqual(EnvPath.splitCliString(""), [])
    }

    func testResolveCliSpawnIsIdentityOnPosix() {
        let resolved = EnvPath.resolveCliSpawn(cli: "claude", args: ["--print", "hello"])
        XCTAssertEqual(resolved.command, "claude")
        XCTAssertEqual(resolved.args, ["--print", "hello"])
    }
}
