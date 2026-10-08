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
// output, reaches the copy half of this (ruling D4). Since album-cleanup (step
// W) a Discover ALBUM on that same column reaches the album half: a temporary
// playlist of the slice, the proof collector, the song guard and the cleaner,
// composed over the copy path's ONE watcher, deletion guard and mode guard.
// Every other case keeps the path it ships with.
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

/// Where the one watcher's end goes. The watcher is held weakly (it owns the
/// closure that reaches this, not the reverse); `handleEnd` is the copy
/// path's own end until an album composition replaces it with the dispatch
/// by entry kind.
private final class DiscoverEndRouter {
    weak var watcher: DiscoverCopyWatcher?
    var handleEnd: ((String) -> Void)?
}

/// What the copy composition builds, for the album composition to share: ONE
/// watcher, ONE deletion guard, ONE mode guard.
private struct DiscoverCopyCore {
    let seams: DiscoverCopySeams
    let watcher: DiscoverCopyWatcher
    let deleter: DiscoverCopyDeleter
    let router: DiscoverEndRouter
    /// The end handler's guarded restore (re-adopts a held restore's copy).
    let restoreAtEnd: (String) -> Void
    /// The end handler's re-adopt of a spared copy.
    let readopt: (String, String) -> Void
    /// S5-S14 over `player`, with this composition's mode guard and deleter.
    let sequenceOver: (_ player: DiscoverCopyPlayerControlling, _ hex: String, _ txn: String,
                       _ request: DiscoverCopyRequest, _ gate: @escaping DiscoverCopyGate,
                       _ progress: @escaping (DiscoverCopyStage) -> Void,
                       _ commitListening: @escaping () -> Void) -> DiscoverCopyPlayResult
}

private func composeDiscoverCopyCore(_ parts: DiscoverCopyRuntimeParts) -> DiscoverCopyCore {
    let journal = parts.journal
    let modeGuard = DiscoverModeGuard(journal: journal, seams: parts.modes)
    let deleter = DiscoverCopyDeleter(journal: journal, run: parts.run)

    // The end handler re-adopts a spared copy, and hands a held restore's
    // copy to the watcher, so it needs the watcher it is a seam of. Held
    // weakly: the watcher owns the closure, not the reverse.
    let router = DiscoverEndRouter()
    let restoreAtEnd: (String) -> Void = { [weak router] txn in
        discoverCopySettleModes(txn: txn, modes: modeGuard,
                                adopt: { router?.watcher?.adopt(txn: $0, hex: $1) },
                                log: parts.log)
    }
    let readopt: (String, String) -> Void = { [weak router] in router?.watcher?.adopt(txn: $0, hex: $1) }
    router.handleEnd = { txn in
        discoverCopyHandleEnd(txn: txn, deleter: deleter, journal: journal,
                              restoreModes: restoreAtEnd, readopt: readopt)
    }
    let watcher = DiscoverCopyWatcher(seams: DiscoverCopyWatcher.Seams(
        read: { discoverCopyPlayerRead(fromScriptOutput: parts.run(discoverCopyObservationScript)) },
        now: parts.now,
        // The watcher owns the router (nothing else may); the router holds
        // the watcher weakly, and its closures reach it only through itself
        // weakly, so there is no cycle.
        enqueueEnd: { txn in
            parts.enqueue { router.handleEnd?(txn) }
        }))
    router.watcher = watcher
    // Every other caller's one guarded restore.
    let settle: (String) -> Void = { txn in
        discoverCopySettleModes(txn: txn, modes: modeGuard,
                                adopt: { watcher.adopt(txn: $0, hex: $1) }, log: parts.log)
    }
    let sequenceOver: (DiscoverCopyPlayerControlling, String, String, DiscoverCopyRequest,
                       @escaping DiscoverCopyGate, @escaping (DiscoverCopyStage) -> Void,
                       @escaping () -> Void) -> DiscoverCopyPlayResult = {
        player, hex, txn, request, gate, progress, commitListening in
        DiscoverCopySequencer(player: player, seams: DiscoverCopySequencer.Seams(
            now: parts.now,
            sleep: parts.sleep,
            gate: gate,
            switchModesOff: { modeGuard.switchOff(txn: txn) },
            restoreModes: { settle(txn) },
            deleteIfOwned: { _ = deleter.end(txn: txn) },
            commitListening: commitListening,
            progress: progress,
            log: parts.log)).run(hex: hex, request: request)
    }

    let seams = DiscoverCopySeams(
        ops: parts.ops,
        journal: journal,
        sequence: { hex, txn, request, gate, progress, commitListening in
            sequenceOver(parts.player, hex, txn, request, gate, progress, commitListening)
        },
        deleteIfOwned: { deleter.end(txn: $0) },
        restoreModes: settle,
        adopt: { watcher.adopt(txn: $0, hex: $1) },
        spandacDataSelected: parts.spandacDataSelected,
        now: parts.now,
        log: parts.log)
    return DiscoverCopyCore(seams: seams, watcher: watcher, deleter: deleter, router: router,
                            restoreAtEnd: restoreAtEnd, readopt: readopt, sequenceOver: sequenceOver)
}

/// The seams a copy play runs through, and the watcher that ends it.
func composeDiscoverCopyRuntime(_ parts: DiscoverCopyRuntimeParts)
    -> (seams: DiscoverCopySeams, watcher: DiscoverCopyWatcher) {
    let core = composeDiscoverCopyCore(parts)
    return (core.seams, core.watcher)
}

// MARK: - The album composition (album-cleanup W)

/// What the album half of the composition reaches beyond the copy parts.
/// Production fills it from the routing coordinator's data client and the
/// backend; a test hands in fakes.
struct DiscoverAlbumRuntimeParts {
    /// B's side file, beside the journal (production: the journal's own store).
    var beforeSet: DiscoverBeforeSetStore
    /// The ensure; asked per play.
    var library: () -> SpanDACLibraryAdding
    /// The relations read; asked per play, per collector item and per reconcile.
    var relations: () -> SpanDACLibraryRelationsReading
    /// Runs the B-script, bounded by `DiscoverAlbumTiming.beforeSetBound`.
    var runBeforeSet: ScriptRunner
    /// Runs one P-read, bounded by `DiscoverAlbumTiming.proofReadTimeout`.
    var runProofRead: ScriptRunner
    /// Runs one song-guard script, bounded by `DiscoverAlbumTiming.guardScriptTimeout`.
    var runGuard: ScriptRunner
    /// The album parts' toasts (production: `discoverToastPoster(status:)`).
    var post: (DiscoverToast) -> Void
}

/// Everything a Discover play-from-here runs on, for both kinds.
struct DiscoverPlayRuntime {
    let copy: DiscoverCopySeams
    let album: DiscoverAlbumSeams
    let watcher: DiscoverCopyWatcher
    let collector: DiscoverAlbumProofCollector
    let cleaner: DiscoverAlbumCleaner
    /// What the watcher's enqueueEnd runs, dispatched by entry kind. Also LH's forced end.
    let handleEnd: (_ txn: String) -> Void
}

/// The copy composition, unchanged, plus the album parts over the SAME
/// watcher, deletion guard and mode guard. The watcher's end is dispatched by
/// the entry's kind: an album entry goes through `discoverAlbumHandleEnd`
/// (the container, then its songs), every other entry through
/// `discoverCopyHandleEnd` exactly as the copy path ships. An entry whose kind
/// cannot be read (the journal unreadable at that moment) takes the album end,
/// which for a copy entry does what the copy end does and nothing more.
func composeDiscoverPlayRuntime(_ parts: DiscoverCopyRuntimeParts,
                                album albumParts: DiscoverAlbumRuntimeParts) -> DiscoverPlayRuntime {
    let core = composeDiscoverCopyCore(parts)
    let journal = parts.journal
    let watcher = core.watcher

    let songGuard = DiscoverOwnedSongDeleter(journal: journal, run: albumParts.runGuard, now: parts.now)
    let cleaner = DiscoverAlbumCleaner(seams: DiscoverAlbumCleaner.Seams(
        journal: journal,
        beforeSet: albumParts.beforeSet,
        guardSong: { songGuard.run(txn: $0, position: $1) },
        enqueue: parts.enqueue,
        post: albumParts.post,
        now: parts.now,
        log: parts.log))
    let collector = DiscoverAlbumProofCollector(seams: DiscoverAlbumProofCollector.Seams(
        journal: journal,
        beforeSet: albumParts.beforeSet,
        relations: albumParts.relations,
        readEntry: { hex in parseDiscoverAlbumEntryRead(albumParts.runProofRead(discoverAlbumProofReadScript(hex: hex))) },
        spandacDataSelected: parts.spandacDataSelected,
        now: parts.now,
        enqueue: parts.enqueue,
        ownedAfterEnd: { cleaner.handToGuard(txn: $0, position: $1) },
        settled: { cleaner.settle(txn: $0) },
        log: parts.log))
    let deleter = core.deleter
    let player = parts.player
    let reconciler = DiscoverAlbumReconciler(seams: DiscoverAlbumReconciler.Seams(
        journal: journal,
        beforeSet: albumParts.beforeSet,
        relations: albumParts.relations,
        findContainers: { name in parseDiscoverAlbumFoundContainers(parts.run(discoverAlbumFindContainerScript(name: name))) },
        // The shipped K8 read: production's player is `AppleScriptDiscoverCopyPlayer(run:)`.
        readEntryIDs: { hex in player.read(hex: hex, k: 1)?.ids },
        deleteIfOwned: { deleter.end(txn: $0) },
        adopt: { watcher.adopt(txn: $0, hex: $1) },
        startProof: { collector.adopt(txn: $0) },
        cleaner: cleaner,
        spandacDataSelected: parts.spandacDataSelected,
        post: albumParts.post,
        now: parts.now,
        log: parts.log))

    let sequenceOver = core.sequenceOver
    let album = DiscoverAlbumSeams(
        library: albumParts.library,
        relations: albumParts.relations,
        beforeSet: albumParts.beforeSet,
        readBeforeSet: { parseDiscoverAlbumBeforeSet(albumParts.runBeforeSet(discoverAlbumBeforeSetScript)) },
        sequence: { hex, txn, request, gate, progress, commitListening in
            sequenceOver(DiscoverAlbumEntryRecorder(player: player, journal: journal, txn: txn),
                         hex, txn, request, gate, progress, commitListening)
        },
        startProof: { collector.adopt(txn: $0) },
        replay: { reconciler.replay($0, atLaunch: $1) })

    let restoreAtEnd = core.restoreAtEnd
    let readopt = core.readopt
    let copyEnd = core.router.handleEnd
    core.router.handleEnd = { txn in
        let kind = (try? journal.entries()).map { entries in entries.first(where: { $0.txn == txn })?.kind }
        switch kind {
        case .some(.some(.albumContainer)), .none:
            discoverAlbumHandleEnd(txn: txn, deleter: deleter, journal: journal,
                                   restoreModes: restoreAtEnd, readopt: readopt, cleaner: cleaner)
        default:
            copyEnd?(txn)
        }
    }
    let router = core.router
    return DiscoverPlayRuntime(copy: core.seams, album: album, watcher: watcher, collector: collector,
                               cleaner: cleaner, handleEnd: { txn in router.handleEnd?(txn) })
}

/// The live copy parts over `journal`: one AppleScript runner bounded by the
/// copy path's script timeout, the routing coordinator's data client, and
/// the shell's action queue.
private func discoverLiveCopyParts(backend: AppleScriptBackend, routing: RoutingCoordinator,
                                   journal: DiscoverCopyJournalStore,
                                   enqueue: @escaping (@escaping () -> Void) -> Void) -> DiscoverCopyRuntimeParts {
    // One AppleScript body inside `tell application "Music"`; nil when the
    // call failed or ran past its bound.
    let run = discoverLiveScriptRunner(backend: backend, timeout: DiscoverCopyTiming.scriptTimeout)
    return DiscoverCopyRuntimeParts(
        journal: journal,
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
        enqueue: enqueue)
}

/// One AppleScript body inside `tell application "Music"`, bounded by
/// `timeout`; nil when the call failed or ran past its bound.
private func discoverLiveScriptRunner(backend: AppleScriptBackend, timeout: TimeInterval) -> ScriptRunner {
    return { script in
        try? backend.runMusicBlocking(script, timeout: timeout)
    }
}

/// The production runtime. `paths` is `.live` in the shell and a temporary
/// directory anywhere else; `enqueue` is the shell's action queue.
func makeDiscoverCopyRuntime(backend: AppleScriptBackend, routing: RoutingCoordinator,
                             paths: DiscoverCopyPaths,
                             enqueue: @escaping (@escaping () -> Void) -> Void)
    -> (seams: DiscoverCopySeams, watcher: DiscoverCopyWatcher) {
    return composeDiscoverCopyRuntime(discoverLiveCopyParts(backend: backend, routing: routing,
                                                            journal: FileDiscoverCopyJournalStore(paths: paths),
                                                            enqueue: enqueue))
}

/// The production runtime for both kinds of play from here (album-cleanup
/// W). `paths` is `.live` in the shell and a temporary directory anywhere
/// else: the journal and B's side files live there, and nowhere else.
/// `enqueue` is the shell's quiet action queue; every album toast goes
/// through `discoverToastPoster(status:)`. The ensure and the relations read
/// come from `routing.dataClient()`, asked each time.
func makeDiscoverPlayRuntime(backend: AppleScriptBackend, routing: RoutingCoordinator, paths: DiscoverCopyPaths,
                             status: StatusStore,
                             enqueue: @escaping (@escaping () -> Void) -> Void) -> DiscoverPlayRuntime {
    let journal = FileDiscoverCopyJournalStore(paths: paths)
    return composeDiscoverPlayRuntime(
        discoverLiveCopyParts(backend: backend, routing: routing, journal: journal, enqueue: enqueue),
        album: DiscoverAlbumRuntimeParts(
            beforeSet: journal,
            library: { routing.dataClient().libraryWrites() },
            relations: { routing.dataClient().libraryRelations() },
            runBeforeSet: discoverLiveScriptRunner(backend: backend, timeout: DiscoverAlbumTiming.beforeSetBound),
            runProofRead: discoverLiveScriptRunner(backend: backend, timeout: DiscoverAlbumTiming.proofReadTimeout),
            runGuard: discoverLiveScriptRunner(backend: backend, timeout: DiscoverAlbumTiming.guardScriptTimeout),
            post: discoverToastPoster(status: status)))
}
