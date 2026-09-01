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

func spawnAlbumWatcher(name: String,
                       uuid: String,
                       ids: Set<String>,
                       launch: ProcessLauncher = detachedLaunch) -> Bool {
    let args: [String]
    do {
        args = try watcherArguments(name: name, uuid: uuid, ids: ids)
    } catch {
        verbose("watcher args failed for \(name): \(error.localizedDescription)")
        return false
    }
    let me = URL(fileURLWithPath: CommandLine.arguments[0])
        .resolvingSymlinksInPath().path
    return launch(me, args)
}
