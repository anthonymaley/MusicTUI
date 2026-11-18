// tools/music/Sources/Backends/WatcherLauncher.swift
import Foundation

/// Launch a detached child of this binary. Returns false if the spawn failed.
///
/// Injected so a launch failure can be simulated: that path has to pause
/// playback and delete the container, and it is not otherwise reachable.
typealias ProcessLauncher = (String, [String]) -> Bool

/// Argument list for the watcher, choosing inline ids or a manifest by size.
func watcherArguments(name: String, uuid: String, ids: Set<String>) throws -> [String] {
    var args = ["__watch-container", name]
    if ids.count > albumWatcherInlineIDLimit {
        let path = try writeAlbumManifest(uuid: uuid, ids: ids)
        args += ["--manifest", path]
    } else {
        args += ["--ids", ids.sorted().joined(separator: ",")]
    }
    return args
}

/// The detached spawn, in the exact shape the 2026-09-01 TCC spike proved:
/// this same binary, all three standard streams redirected to nullDevice, and
/// `run()` never waited on, so the child is reparented to launchd when this
/// process exits. Measured: 34 of 34 Apple Events succeeded from such a child,
/// across runs up to 900 seconds, with zero -1743 denials.
func detachedLaunch(_ executable: String, _ arguments: [String]) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: executable)
    p.arguments = arguments
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do {
        try p.run()
        return true
    } catch {
        verbose("watcher spawn failed: \(error.localizedDescription)")
        return false
    }
}

/// The executable the detached children are spawned from: this same binary, as
/// an absolute path with every symlink resolved.
///
/// Never `CommandLine.arguments[0]` against the current directory: run by bare
/// name (`music` found on PATH) argv[0] is just "music", and "<cwd>/music" is not
/// a file, so the spawn failed and a Mac DAC route play refused to start (live
/// check 2026-11-17, finding 5). In order:
///   1. the system's own answer (`_NSGetExecutablePath`), which is the running
///      image whatever argv[0] says;
///   2. the bundle's executable;
///   3. argv[0] itself: a path with a slash resolves against `cwd`, a bare name
///      is searched for on `searchPath` (PATH), the way the shell found it.
/// The last resort, with nothing found, is argv[0] against `cwd` (the old
/// behaviour), so a launch failure is still reported by the launcher.
func runningExecutablePath(arguments: [String] = CommandLine.arguments,
                           cwd: String = FileManager.default.currentDirectoryPath,
                           systemPath: () -> String? = systemExecutablePath,
                           bundlePath: () -> String? = { Bundle.main.executableURL?.path },
                           searchPath: String? = ProcessInfo.processInfo.environment["PATH"]) -> String {
    func canonical(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
    func usable(_ path: String?) -> String? {
        guard let path, path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return canonical(path)
    }
    if let found = usable(systemPath()) { return found }
    if let found = usable(bundlePath()) { return found }
    let argv0 = arguments.first ?? ""
    if argv0.contains("/") {
        let absolute = argv0.hasPrefix("/") ? argv0 : URL(fileURLWithPath: cwd).appendingPathComponent(argv0).path
        if let found = usable(URL(fileURLWithPath: absolute).standardized.path) { return found }
    } else if !argv0.isEmpty {
        for directory in (searchPath ?? "").split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = directory.hasPrefix("/") ? String(directory) + "/" + argv0
                : URL(fileURLWithPath: cwd).appendingPathComponent(String(directory)).appendingPathComponent(argv0).path
            if let found = usable(candidate) { return found }
        }
    }
    return canonical(URL(fileURLWithPath: argv0, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true)).path)
}

/// `_NSGetExecutablePath`: the path of the running image as the loader knows it
/// (it may hold symlinks or `..`; the caller canonicalises). nil if it fails.
func systemExecutablePath() -> String? {
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    guard size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
    return String(cString: buffer)
}

func spawnAlbumWatcher(name: String,
                       uuid: String,
                       ids: Set<String>,
                       executable: String = runningExecutablePath(),
                       launch: ProcessLauncher = detachedLaunch) -> Bool {
    let args: [String]
    do {
        args = try watcherArguments(name: name, uuid: uuid, ids: ids)
    } catch {
        verbose("watcher args failed for \(name): \(error.localizedDescription)")
        return false
    }
    let launched = launch(executable, args)
    if !launched, let manifestIndex = args.firstIndex(of: "--manifest"), manifestIndex + 1 < args.count {
        // A manifest was written (large album) but the watcher process never
        // started, so nobody will ever own or remove this file — the manifest
        // is owned by a RUNNING watcher, and there isn't one. Left behind,
        // this would sit beside the auth files permanently rather than for
        // at most six hours.
        removeAlbumManifest(path: args[manifestIndex + 1])
    }
    return launched
}

// MARK: - the run-queue runner (mac-route-plan.md, step P5, D1)

/// Argument list for `__run-queue`: the queue's persistent IDs IN ORDER, inline
/// or, past the watcher's own limit, through an ordered manifest file. The label
/// is one `--label=` argument, so a label that starts with a dash is not read as
/// an option.
///
/// `reservation` is the ordering the PARENT took for the child under the output
/// lock (the fence and the lease, for the child's owner id): it goes before the
/// queue, so the queue stays the last argument.
func runQueueArguments(label: String, uuid: String, ids: [String],
                       manifestDirectory: String? = nil,
                       reservation: RunQueueReservation? = nil) throws -> [String] {
    var args = ["__run-queue", uuid, "--label=\(label)"]
    if let reservation { args += ["--fence", String(reservation.fence), "--owner", reservation.owner] }
    if ids.count > albumWatcherInlineIDLimit {
        let path = try writeRunQueueManifest(uuid: uuid, ids: ids, directory: manifestDirectory)
        args += ["--manifest", path]
    } else {
        args += ["--ids", ids.joined(separator: ",")]
    }
    return args
}

/// Starts the detached runner that plays `ids` one song at a time on the Mac DAC
/// route. The same detached shape as the album watcher (`detachedLaunch`); a
/// failed spawn removes the manifest it wrote, because only a RUNNING runner
/// would ever remove it.
func spawnRunQueue(label: String,
                   uuid: String,
                   ids: [String],
                   manifestDirectory: String? = nil,
                   reservation: RunQueueReservation? = nil,
                   executable: String = runningExecutablePath(),
                   launch: ProcessLauncher = detachedLaunch) -> Bool {
    let args: [String]
    do {
        args = try runQueueArguments(label: label, uuid: uuid, ids: ids, manifestDirectory: manifestDirectory,
                                     reservation: reservation)
    } catch {
        verbose("run-queue args failed for \(label): \(error.localizedDescription)")
        return false
    }
    let launched = launch(executable, args)
    if !launched, let i = args.firstIndex(of: "--manifest"), i + 1 < args.count {
        removeAlbumManifest(path: args[i + 1])
    }
    return launched
}
