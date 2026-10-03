// tools/music/Sources/TUI/DiscoverFromHereWiring.swift
//
// Discover "play from here" on Apple's own copy of a playlist: the composition
// (score step C6). Nothing here decides anything. It hands the parts to each
// other: the journal, the mode guard, the deletion guard, the end watcher, the
// player and the sequencer become the `DiscoverCopySeams` the lifecycle
// coordinator runs a copy play through, and the routing coordinator's
// reservation becomes the gate phase B re-enters the boundary by.
//
// Only a Discover PLAYLIST with a `pl.` id, with SpanDAC data on the MusicTUI
// output, reaches any of this (ruling D4). Albums and every other case keep
// the path they ship with.
import Foundation

// MARK: - Which container takes the path

/// The copy-play request for a Discover container, or nil when the container
/// is not a catalogue playlist: an album, a station, a song, or a playlist
/// whose id is not a `pl.` one. `rows` are the FULL rows he was shown.
func discoverCopyRequest(container: DiscoverItem, rows: [DiscoverItem], selected: Int) -> DiscoverCopyRequest? {
    guard case .playlist = container.detail, container.id.hasPrefix("pl.") else { return nil }
    return DiscoverCopyRequest(playlistID: container.id, playlistTitle: container.name,
                               rows: rows, selected: selected)
}

// MARK: - Phase A and the gate

/// What phase A captured inside the routing boundary, for phase B to run on.
struct DiscoverCopyPhaseA: Equatable {
    let slot: DiscoverCopyReservation
    let reservation: RoutingReservation
}

/// PHASE A, for the `.addContainer` branch. Two non-blocking steps: the one
/// copy-play slot, then the routing reservation (`reservation` is
/// `routing.reservationForThisBranch`). Nil: the shell is exiting, nothing
/// runs and nothing is said. A throw leaves the slot free.
func discoverCopyPhaseA(_ request: DiscoverCopyRequest, lifecycle: DiscoverLifecycleCoordinator,
                        reservation: () throws -> RoutingReservation) throws -> DiscoverCopyPhaseA? {
    switch lifecycle.reserveCopyPlay(request) {
    case .reserved(let slot):
        do {
            return DiscoverCopyPhaseA(slot: slot, reservation: try reservation())
        } catch {
            lifecycle.cancelCopyPlay(slot)
            throw error
        }
    case .busy:
        throw ActionError(message: discoverCopyBusyText(playlist: request.playlistTitle))
    case .exiting:
        return nil
    case .notWired:
        throw ActionError(message: pickASpanDACOutput)
    }
}

/// Phase B's way back into the routing boundary: `body` runs only while the
/// reservation still holds. A thrown re-entry error counts as moved.
func discoverCopyGate(routing: RoutingCoordinator, reservation: RoutingReservation) -> DiscoverCopyGate {
    return { body in
        do {
            switch try routing.whileReserved(reservation, body) {
            case .holds: return .ran
            case .superseded: return .superseded
            case .sourceChanged: return .sourceChanged
            }
        } catch {
            return .sourceChanged
        }
    }
}

// MARK: - The composition

/// Everything the composition reaches outside itself. Production fills it
/// from the real backend and coordinator; a test hands in fakes.
struct DiscoverCopyRuntimeParts {
    var journal: DiscoverCopyJournalStore
    var ops: () -> SpanDACCatalogPlaylistOps
    var spandacDataSelected: () -> Bool
    var player: DiscoverCopyPlayerControlling
    var modes: DiscoverModeGuard.Seams
    /// Runs the deletion guard's script and the watcher's one read per tick.
    var run: ScriptRunner
    var now: () -> Date
    var sleep: (TimeInterval) -> Void
    var log: (String) -> Void
    /// Onto the shell's serial action queue, with no status post.
    var enqueue: (@escaping () -> Void) -> Void
}

/// The seams a copy play runs through, and the watcher that ends it.
func composeDiscoverCopyRuntime(_ parts: DiscoverCopyRuntimeParts)
    -> (seams: DiscoverCopySeams, watcher: DiscoverCopyWatcher) {
    let journal = parts.journal
    let modeGuard = DiscoverModeGuard(journal: journal, seams: parts.modes)
    let deleter = DiscoverCopyDeleter(journal: journal, run: parts.run)

    // The end handler re-adopts a spared copy, and hands a held restore's
    // copy to the watcher, so it needs the watcher it is a seam of. Held
    // weakly: the watcher owns the closure, not the reverse.
    final class WatcherBox { weak var watcher: DiscoverCopyWatcher? }
    let box = WatcherBox()
    let watcher = DiscoverCopyWatcher(seams: DiscoverCopyWatcher.Seams(
        read: { discoverCopyPlayerRead(fromScriptOutput: parts.run(discoverCopyObservationScript)) },
        now: parts.now,
        enqueueEnd: { txn in
            parts.enqueue {
                discoverCopyHandleEnd(txn: txn, deleter: deleter, journal: journal,
                                      restoreModes: {
                                          discoverCopySettleModes(txn: $0, modes: modeGuard,
                                                                  adopt: { box.watcher?.adopt(txn: $0, hex: $1) },
                                                                  log: parts.log)
                                      },
                                      readopt: { box.watcher?.adopt(txn: $0, hex: $1) })
            }
        }))
    box.watcher = watcher
    // Every other caller's one guarded restore.
    let settle: (String) -> Void = { txn in
        discoverCopySettleModes(txn: txn, modes: modeGuard,
                                adopt: { watcher.adopt(txn: $0, hex: $1) }, log: parts.log)
    }

    let seams = DiscoverCopySeams(
        ops: parts.ops,
        journal: journal,
        sequence: { hex, txn, request, gate, progress, commitListening in
            DiscoverCopySequencer(player: parts.player, seams: DiscoverCopySequencer.Seams(
                now: parts.now,
                sleep: parts.sleep,
                gate: gate,
                switchModesOff: { modeGuard.switchOff(txn: txn) },
                restoreModes: { settle(txn) },
                deleteIfOwned: { _ = deleter.end(txn: txn) },
                commitListening: commitListening,
                progress: progress,
                log: parts.log)).run(hex: hex, request: request)
        },
        deleteIfOwned: { deleter.end(txn: $0) },
        restoreModes: settle,
        adopt: { watcher.adopt(txn: $0, hex: $1) },
        spandacDataSelected: parts.spandacDataSelected,
        now: parts.now,
        log: parts.log)
    return (seams, watcher)
}

/// The production runtime. `paths` is `.live` in the shell and a temporary
/// directory anywhere else; `enqueue` is the shell's action queue.
func makeDiscoverCopyRuntime(backend: AppleScriptBackend, routing: RoutingCoordinator,
                             paths: DiscoverCopyPaths,
                             enqueue: @escaping (@escaping () -> Void) -> Void)
    -> (seams: DiscoverCopySeams, watcher: DiscoverCopyWatcher) {
    // One AppleScript body inside `tell application "Music"`; nil when the
    // call failed or ran past its bound.
    let run: ScriptRunner = { script in
        try? syncRun { try await backend.runMusic(script, timeout: DiscoverCopyTiming.scriptTimeout) }
    }
    return composeDiscoverCopyRuntime(DiscoverCopyRuntimeParts(
        journal: FileDiscoverCopyJournalStore(paths: paths),
        ops: { routing.dataClient().catalogPlaylistOps() },
        spandacDataSelected: {
            if case .consistent(.spandacMac, _) = routing.selection { return true }
            return false
        },
        player: AppleScriptDiscoverCopyPlayer(run: run),
        modes: .live(backend: backend, run: run),
        run: run,
        now: { Date() },
        sleep: { Thread.sleep(forTimeInterval: $0) },
        log: { verbose($0) },
        enqueue: enqueue))
}
