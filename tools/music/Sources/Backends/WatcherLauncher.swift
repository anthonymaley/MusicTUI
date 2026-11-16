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
    let launched = launch(me, args)
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
                   launch: ProcessLauncher = detachedLaunch) -> Bool {
    let args: [String]
    do {
        args = try runQueueArguments(label: label, uuid: uuid, ids: ids, manifestDirectory: manifestDirectory,
                                     reservation: reservation)
    } catch {
        verbose("run-queue args failed for \(label): \(error.localizedDescription)")
        return false
    }
    let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    let launched = launch(me, args)
    if !launched, let i = args.firstIndex(of: "--manifest"), i + 1 < args.count {
        removeAlbumManifest(path: args[i + 1])
    }
    return launched
}
