// The execution half of Source Mode v1's routing seam.
//
// docs/plans/2026-09-13-routing-seam-design.md, after Codex's design review of
// the same day. `routeAction` is the pure policy: WHERE an action goes. This
// makes that decision at the moment the action RUNS, against the mode held in
// memory, inside one ordering boundary shared with mode switching.
//
// **Why no shared playback protocol.** The plan this replaces had Music.app and
// the source implement one `PlaybackBackend`. Music.app's play entry points are
// not catalogue-ID shaped (Library resolves positions in playlist "Library",
// Playlists play by name and position, Discover builds containers), so a shared
// protocol either changes how Music.app plays, breaking DoD 7, or carries
// methods no Music.app caller uses. Each branch here is handed the code it
// already runs; only the choice between them is shared.
//
// **Why the route is read inside the lock (Codex B1).** The shell's
// `ActionRunner` runs closures later, on its own serial queue. A route decided
// when a key is pressed can therefore run after a mode switch commits, and a
// Music.app command would reach Music.app from Source Mode. Reading the mode
// under the same lock the switch holds makes that unrepresentable, whichever
// queue the caller is on.
import Foundation

final class RoutingCoordinator {

    /// The outcome of a switch that went ahead or had nothing to do. A switch
    /// that did not happen throws instead, so it cannot be mistaken for one.
    enum SwitchResult: Equatable {
        case alreadyInMode
        case switched(to: PlaybackMode)
    }

    private let store: PlaybackModeStore
    private let makeSource: () -> SourceAppClient

    /// Held for the whole of an action or a switch: the ordering boundary.
    private let order = NSLock()
    /// Guards `current` and `source` only, so reading `mode` never waits for a
    /// slow AppleScript round trip holding `order`.
    private let state = NSLock()
    private var current: PlaybackMode
    private var source: SourceAppClient?
    private var reachedBoundary: (() -> Void)?

    /// A unique key per instance. `ObjectIdentifier.hashValue` is not
    /// guaranteed unique, so it cannot name "this coordinator" (Codex, 11:47).
    private let reentryKey = "RoutingCoordinator.\(UUID().uuidString)"

    /// Reads the persisted selection ONCE. From here on the in-memory mode is
    /// the truth for the life of the process, and only a switch changes it.
    init(store: PlaybackModeStore, makeSource: @escaping () -> SourceAppClient) {
        self.store = store
        self.makeSource = makeSource
        self.current = store.mode()
    }

    /// The composition both processes use: the TUI once at launch, each CLI
    /// command once per invocation, so the CLI obeys the same selection the
    /// Output tab made (Codex B2).
    static func live(store: PlaybackModeStore = PlaybackModeStore()) -> RoutingCoordinator {
        RoutingCoordinator(store: store, makeSource: { SourceAppClient() })
    }

    var mode: PlaybackMode {
        state.lock(); defer { state.unlock() }
        return current
    }

    /// Runs exactly one branch for `action`, chosen now rather than when it was
    /// requested.
    ///
    /// A refusal throws `ActionError` carrying the matrix's reason: the shell's
    /// `ActionRunner` shows `message` on the footer, and a CLI command that lets
    /// it escape prints the same words, because `ActionError` is a
    /// `LocalizedError` (`RoutingCoordinatorTests` pins both). Unsupported is
    /// stated, never a silent no-op. The source client is built only when a
    /// `.source` branch runs, which is what keeps Music.app mode from ever
    /// constructing one (DoD 7).
    ///
    /// **Branches must not wait synchronously on work that calls back into this
    /// coordinator from another thread.** The same-thread reentrancy guard below
    /// cannot see that, and it would deadlock.
    func perform(_ action: MusicTUIAction,
                 musicApp: () throws -> Void,
                 source: (SourceAppClient) throws -> Void,
                 unaffected: () throws -> Void) throws {
        try exclusively {
            switch routeAction(action, in: mode) {
            case .musicApp:        try musicApp()
            case .unaffected:      try unaffected()
            case .source:          try source(sourceClient())
            case .refused(let why): throw ActionError(message: why)
            }
        }
    }

    /// Binding rule 4 and Anthony's ruling 12.3 as one ordered transaction.
    /// **Every committed switch has paused the outgoing player AND dropped its
    /// queue**; if either cannot be done, the mode does not change.
    ///
    /// 1. The incoming mode must be selectable. `readiness` is evaluated HERE,
    ///    inside the boundary, because a switch can wait behind a slow action
    ///    and a value computed at the keypress would be stale (Codex, 11:47).
    /// 2. The OUTGOING player is paused and must confirm it is not playing.
    /// 3. The outgoing queue is dropped.
    /// 4. The selection is saved, so this session and the next launch cannot
    ///    drive different players.
    /// 5. The mode commits in memory.
    ///
    /// **Why the drop precedes the save.** No order is atomic: dropping after
    /// the commit could commit a switch whose queue survived, which 12.3 does
    /// not allow. Dropping first means a failed save leaves the person in the
    /// old mode, paused, with its queue gone. That partial outcome is stated in
    /// the error, not hidden behind "still using": 12.3 requires warning and
    /// confirmation only while playback is ACTIVE, so an idle queue can be lost
    /// with no confirmation at all (Codex, 12:40). Any confirmation is the
    /// caller's, before this is called, because the coordinator cannot ask
    /// anyone anything.
    ///
    /// **Only positive evidence confirms a pause.** A source `pauseOutgoing` must
    /// return true only on a reported paused or stopped status, or on
    /// independently established process absence. `SourceAppError.notRunning`
    /// is NOT such evidence: it also covers a failed connect or write to a live
    /// app that may still be playing, and treating it as stopped could leave
    /// both players running (rule 4, DoD 8).
    func switchMode(to target: PlaybackMode,
                    readiness: () -> SourceReadiness,
                    pauseOutgoing: (PlaybackMode) throws -> Bool,
                    dropQueue: (PlaybackMode) throws -> Void) throws -> SwitchResult {
        try exclusively {
            let outgoing = mode
            guard target != outgoing else { return .alreadyInMode }

            let ready = target == .source ? readiness() : .ready
            guard outputModeSelectable(target, readiness: ready) else {
                throw ActionError(message: "MusicTUI Source is \(ready.label); still using \(name(outgoing))")
            }

            let paused = (try? pauseOutgoing(outgoing)) ?? false
            guard paused else {
                throw ActionError(message: "Couldn't confirm \(name(outgoing)) paused; still using it")
            }

            do {
                try dropQueue(outgoing)
            } catch {
                throw ActionError(message: "Couldn't clear \(name(outgoing))'s queue; still using it")
            }

            guard store.set(target) else {
                throw ActionError(message: "Couldn't save the playback mode; \(name(outgoing))'s queue was cleared, still using \(name(outgoing))")
            }

            state.lock(); current = target; state.unlock()
            return .switched(to: target)
        }
    }

    // MARK: - private

    /// The factory runs OUTSIDE `state`, so a factory that reads `mode` cannot
    /// deadlock. `order` is already held, so two clients are never built.
    private func sourceClient() -> SourceAppClient {
        state.lock()
        let cached = source
        state.unlock()
        if let cached { return cached }
        let made = makeSource()
        state.lock(); source = made; state.unlock()
        return made
    }

    /// TEST SEAM. Called on the entering thread just before it waits for the
    /// ordering boundary, so a test can prove a competing call has reached the
    /// lock instead of sleeping and hoping (Codex, 11:47).
    func onReachingBoundary(_ hook: (() -> Void)?) {
        state.lock(); reachedBoundary = hook; state.unlock()
    }

    private func name(_ mode: PlaybackMode) -> String {
        switch mode {
        case .musicApp: return "Music.app"
        case .source:   return "MusicTUI Source"
        }
    }

    /// A branch that calls back into the coordinator would wait on `order`
    /// forever and wedge the shell's action queue with nothing on screen, the
    /// shape of the `syncRun` deadlock this repo has already paid for. It
    /// throws instead.
    private func exclusively<T>(_ body: () throws -> T) throws -> T {
        let marker = Thread.current.threadDictionary
        guard marker[reentryKey] == nil else {
            throw ActionError(message: "Internal error: a playback action started another inside itself")
        }
        state.lock()
        let hook = reachedBoundary
        state.unlock()
        hook?()
        order.lock()
        marker[reentryKey] = true
        defer {
            marker.removeObject(forKey: reentryKey)
            order.unlock()
        }
        return try body()
    }
}
