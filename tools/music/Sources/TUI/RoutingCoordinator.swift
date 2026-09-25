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

/// Slice 3 Part 2, D3: "choice inside the lock, round trip outside, result
/// carries an epoch." What `RoutingCoordinator.choose` hands back instead of
/// running a closure, so the caller's own read happens outside the boundary.
struct ProviderChoice<Provider> {
    let provider: Provider
    /// `RoutingCoordinator.epoch` at the moment the choice was made.
    let epoch: Int
    /// `RoutingCoordinator.mode` at the moment the choice was made.
    let mode: PlaybackMode
}

final class RoutingCoordinator {

    /// The outcome of a switch that went ahead or had nothing to do. A switch
    /// that did not happen throws instead, so it cannot be mistaken for one.
    enum SwitchResult: Equatable {
        case alreadyInMode
        case switched(to: PlaybackMode)
    }

    private let store: PlaybackModeStore
    private let makeSource: () -> SourceAppClient

    /// The cross-process output lock (slice 3, D6), exposed read-only so the
    /// CLI can take it directly around a playback mutation. The CLI's mutation
    /// already runs inside `perform`, which holds `order` and has set the
    /// re-entry marker, so there is deliberately NO method here that enters
    /// `exclusively` on the CLI's behalf. Nil only for coordinators built
    /// directly in tests; production builds through `live`, which always
    /// passes one.
    let outputLock: OutputLock?

    /// Which surface this process IS. One per process, set at composition, so a
    /// TUI call site cannot claim to be the CLI and vice versa (ruling 12.14).
    private let surface: InvocationSurface

    /// Held for the whole of an action or a switch: the ordering boundary.
    private let order = NSLock()
    /// Guards `current` and `source` only, so reading `mode` never waits for a
    /// slow AppleScript round trip holding `order`.
    private let state = NSLock()
    private var current: PlaybackMode
    private var source: SourceAppClient?
    private var reachedBoundary: (() -> Void)?

    /// Slice 3 Part 2, D3. Starts at 0; incremented exactly once per
    /// COMMITTED switch (never on `alreadyInMode`, a refused switch — readiness,
    /// an unconfirmed pause, a failed queue drop, a failed save — or a
    /// foreign-process mismatch caught by `underOutputLock`). In-process only,
    /// like `mode` itself: another TUI process's switch is not seen by this
    /// one's epoch (true today).
    private var _epoch = 0

    /// A unique key per instance. `ObjectIdentifier.hashValue` is not
    /// guaranteed unique, so it cannot name "this coordinator" (Codex, 11:47).
    private let reentryKey = "RoutingCoordinator.\(UUID().uuidString)"

    /// Reads the persisted selection ONCE. From here on the in-memory mode is
    /// the truth for the life of the process, and only a switch changes it.
    init(store: PlaybackModeStore,
         surface: InvocationSurface,
         makeSource: @escaping () -> SourceAppClient,
         outputLock: OutputLock? = nil) {
        self.store = store
        self.surface = surface
        self.makeSource = makeSource
        self.outputLock = outputLock
        self.current = store.mode()
    }

    /// The composition both processes use: the TUI once at launch with `.tui`,
    /// each CLI command once per invocation with `.cli`, so the CLI obeys the
    /// same selection the Output tab made (Codex B2) while 12.14 still tells the
    /// two surfaces apart. It always carries the output lock beside the
    /// store's mode.json, so a temp store gets a temp lock.
    static func live(store: PlaybackModeStore = PlaybackModeStore(),
                     surface: InvocationSurface) -> RoutingCoordinator {
        RoutingCoordinator(store: store, surface: surface, makeSource: { SourceAppClient() }, outputLock: OutputLock(path: store.lockPath))
    }

    var mode: PlaybackMode {
        state.lock(); defer { state.unlock() }
        return current
    }

    /// Slice 3 Part 2, D3. The epoch a result is stamped with when its
    /// provider was chosen; a caller compares its own stamp against this at
    /// drain time and drops a result whose epoch has moved on.
    var epoch: Int {
        state.lock(); defer { state.unlock() }
        return _epoch
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
            switch routeAction(action, in: mode, from: surface) {
            case .musicApp:        try musicApp()
            case .unaffected:      try unaffected()
            case .source:          try source(sourceClient())
            case .refused(let why): throw ActionError(message: why)
            }
        }
    }

    /// Chooses a provider for `action`, reading mode and epoch together with
    /// the routing decision under the same ordering boundary `perform` uses —
    /// so a switch cannot land between "which provider" and "what epoch this
    /// is". A refused route throws exactly as `perform`'s does.
    ///
    /// **`musicApp` and `source` must only CONSTRUCT a provider.** They run
    /// INSIDE the boundary, so they must be cheap and synchronous, never the
    /// round trip itself: the whole point of returning a `ProviderChoice`
    /// rather than running a closure is that the caller's own read (a socket
    /// round trip, in Radio and Discover) happens on its own thread AFTER this
    /// returns, so it can never hold the switch transaction open (a slow read
    /// must not delay a switch).
    func choose<Provider>(_ action: MusicTUIAction,
                          musicApp: () throws -> Provider,
                          source: (SourceAppClient) throws -> Provider) throws -> ProviderChoice<Provider> {
        try exclusively {
            switch routeAction(action, in: mode, from: surface) {
            case .musicApp:
                return ProviderChoice(provider: try musicApp(), epoch: epoch, mode: mode)
            case .source:
                return ProviderChoice(provider: try source(sourceClient()), epoch: epoch, mode: mode)
            case .unaffected:
                throw ActionError(message: "Internal error: \(action) has no provider to choose")
            case .refused(let why):
                throw ActionError(message: why)
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
    ///
    /// **The whole transaction holds the output lock (slice 3, D6)**, taken
    /// after `order` and never before it, so a CLI playback change in another
    /// process cannot land between the pause and the commit. See
    /// `underOutputLock` for the waiting, revalidation and refusal rules.
    func switchMode(to target: PlaybackMode,
                    readiness: () -> SourceReadiness,
                    pauseOutgoing: (PlaybackMode) throws -> Bool,
                    dropQueue: (PlaybackMode) throws -> Void) throws -> SwitchResult {
        try exclusively { try underOutputLock {
            let outgoing = mode
            guard target != outgoing else { return .alreadyInMode }

            let ready = target == .source ? readiness() : .ready
            guard outputModeSelectable(target, readiness: ready) else {
                throw ActionError(message: "Bridge is \(ready.label); still using \(name(outgoing))")
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

            // D3: the epoch moves exactly here, with the mode — the only path
            // that reaches a COMMITTED switch. Every earlier `throw` above
            // returns before this line, so a refused switch never touches it.
            state.lock(); current = target; _epoch += 1; state.unlock()
            return .switched(to: target)
        } }
    }

    // MARK: - private

    /// D6, the switch's side. Holds the cross-process lock for `body` and
    /// releases it on every exit path. After acquiring, the persisted mode must
    /// still be the mode held in memory: another process that moved it has made
    /// this switch's idea of the outgoing player stale, and a mismatch refuses
    /// rather than re-routes. Waiting past the bound, or a lock file that
    /// cannot be opened, refuses in the switch's words (fail closed). A holder
    /// is never forced to release.
    private func underOutputLock<T>(_ body: () throws -> T) throws -> T {
        guard let outputLock else { return try body() }
        do {
            return try outputLock.withLock {
                guard store.mode() == mode else {
                    throw ActionError(message: OutputLock.tuiModeChangedMessage)
                }
                return try body()
            }
        } catch let error as OutputLockError {
            // A switch is always the Output tab's, whatever surface built the
            // coordinator, so it refuses in the switch's words.
            throw ActionError(message: error.message(for: .tui))
        }
    }

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

    /// The name a PERSON reads. Ruling 12.15 (2026-09-15): the user-facing
    /// output is **Bridge**; the app and the internal components keep the name
    /// MusicTUI Source. Type names are deliberately not renamed with it.
    private func name(_ mode: PlaybackMode) -> String {
        switch mode {
        case .musicApp: return "Music.app"
        case .source:   return "Bridge"
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
