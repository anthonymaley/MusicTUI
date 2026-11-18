import XCTest
@testable import music

/// Finding 5 (live check 2026-11-17): `music play --song X` run by bare name
/// refused to start the queue because the detached runner's executable was
/// `CommandLine.arguments[0]` ("music") resolved against the current directory.
/// Nothing here starts a process: the launcher is a closure that records.
final class RunningExecutableTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("running-exe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeExecutable(_ name: String, in folder: URL? = nil) throws -> URL {
        let url = (folder ?? dir).appendingPathComponent(name)
        try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func resolved(_ url: URL) -> String { url.resolvingSymlinksInPath().path }

    /// The bare name `music` run from another directory: the executable is the one
    /// the system says is running, never "<cwd>/music".
    func testBareNameUsesTheSystemsExecutablePathNotTheCwd() throws {
        let real = try makeExecutable("music")
        let elsewhere = dir.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let path = runningExecutablePath(arguments: ["music"], cwd: elsewhere.path,
                                         systemPath: { real.path }, bundlePath: { nil }, searchPath: nil)
        XCTAssertEqual(path, resolved(real))
        XCTAssertFalse(path.hasPrefix(elsewhere.path))
    }

    /// A Homebrew-style symlink to the keg: the child is the keg binary.
    func testSymlinkIsResolved() throws {
        let keg = dir.appendingPathComponent("keg", isDirectory: true)
        try FileManager.default.createDirectory(at: keg, withIntermediateDirectories: true)
        let real = try makeExecutable("music", in: keg)
        let link = dir.appendingPathComponent("music-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let path = runningExecutablePath(arguments: ["music"], cwd: "/",
                                         systemPath: { link.path }, bundlePath: { nil }, searchPath: nil)
        XCTAssertEqual(path, resolved(real))
    }

    /// The system's answer unavailable: the bundle's executable, then argv[0].
    func testFallsBackToTheBundleExecutable() throws {
        let real = try makeExecutable("music")
        let path = runningExecutablePath(arguments: ["music"], cwd: "/nowhere",
                                         systemPath: { nil }, bundlePath: { real.path }, searchPath: nil)
        XCTAssertEqual(path, resolved(real))
    }

    /// Last resorts for a bare name: a PATH search, never the cwd first.
    func testBareNameWithNothingElseIsFoundOnPATH() throws {
        let bin = dir.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let real = try makeExecutable("music", in: bin)
        let cwd = dir.appendingPathComponent("cwd", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        _ = try makeExecutable("music", in: cwd)   // a decoy beside the cwd must not win
        let path = runningExecutablePath(arguments: ["music"], cwd: cwd.path,
                                         systemPath: { nil }, bundlePath: { nil },
                                         searchPath: "/definitely/not/here:\(bin.path)")
        XCTAssertEqual(path, resolved(real))
    }

    /// A path argv[0] (it has a slash) still resolves against the cwd when the
    /// system and the bundle say nothing.
    func testRelativePathArgvResolvesAgainstTheCwdAsALastResort() throws {
        let real = try makeExecutable("music")
        let path = runningExecutablePath(arguments: ["./music"], cwd: dir.path,
                                         systemPath: { nil }, bundlePath: { nil }, searchPath: nil)
        XCTAssertEqual(path, resolved(real))
    }

    /// The real thing, on this test process: an absolute, existing, executable file.
    func testTheRealPathIsAnExistingAbsoluteExecutable() {
        let path = runningExecutablePath()
        XCTAssertTrue(path.hasPrefix("/"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path))
    }

    // MARK: both spawns hand the launcher the running executable

    func testSpawnRunQueueLaunchesTheRunningExecutable() {
        var launchedWith: String?
        let ok = spawnRunQueue(label: "L", uuid: UUID().uuidString, ids: ["0123456789ABCDEF"],
                               executable: "/keg/bin/music") { exe, _ in launchedWith = exe; return true }
        XCTAssertTrue(ok)
        XCTAssertEqual(launchedWith, "/keg/bin/music")
    }

    func testSpawnAlbumWatcherLaunchesTheRunningExecutable() {
        var launchedWith: String?
        let ok = spawnAlbumWatcher(name: "__album__ U — A", uuid: "U", ids: ["ID1"],
                                   executable: "/keg/bin/music") { exe, _ in launchedWith = exe; return true }
        XCTAssertTrue(ok)
        XCTAssertEqual(launchedWith, "/keg/bin/music")
    }

    /// With no `executable:` given (every real call), each spawn launches what the
    /// real resolver says, not argv[0].
    func testEachSpawnsDefaultExecutableIsTheRealResolversResult() {
        var runner: String?, watcher: String?
        XCTAssertTrue(spawnRunQueue(label: "L", uuid: UUID().uuidString, ids: ["0123456789ABCDEF"]) { exe, _ in
            runner = exe; return true })
        XCTAssertTrue(spawnAlbumWatcher(name: "__album__ U — A", uuid: "U", ids: ["ID1"]) { exe, _ in
            watcher = exe; return true })
        XCTAssertEqual(runner, runningExecutablePath())
        XCTAssertEqual(watcher, runningExecutablePath())
    }
}
