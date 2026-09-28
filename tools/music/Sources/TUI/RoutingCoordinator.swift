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
//
// **Two axes (score: data route and output, C-EPOCH).** Where MusicTUI's
// music DATA comes from is a selection of its own, beside the output. The
// coordinator holds both: `mode`/`epoch` for the output, exactly as before,
// and the data selection with its own `dataEpoch`, read once at init and
// changed only by `acceptSpanDACData` and `stopUsingSpanDACData`. `choose`
// routes by the data axis and hands the DATA client (always SpanDAC on this
// Mac); `perform` routes by the sound axis and hands the OUTPUT client. Open
// data never constructs a SpanDAC client, and neither does a blocked output
// (C-REPAIR), except the one pause `stopUsingSpanDACData` may need. "An
// install that never opens Output behaves exactly as it ships" holds only
// BEFORE a person accepts SpanDAC as the data source; after that, data comes
// from SpanDAC whether or not they open Output again.
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
    /// `RoutingCoordinator.dataEpoch` at the moment the choice was made.
    let dataEpoch: Int
    /// Both selections at the moment the choice was made, so a caller can
    /// tell which data source its rows came from.
    let selection: EffectiveSelection

    /// What a read-then-play hands `perform(_:expecting:...)`.
    var stamp: (epoch: Int, dataEpoch: Int) { (epoch, dataEpoch) }
}

/// The outcome of accepting SpanDAC as the data source.
enum DataSwitchResult: Equatable {
    case alreadySelected
    case switched(to: DataProviderSelection)
}

/// The outcome of "Stop using SpanDAC for music data".
enum StopUsingSpanDACResult: Equatable {
    /// Data was MusicTUI's own and no output was blocked: nothing to do.
    case alreadyOpen
    /// Data is MusicTUI's own again, and the output is MusicTUI.
    case stopped
    /// Data is MusicTUI's own again, but the SpanDAC output could not be left
    /// (C-REPAIR: an unconfirmed pause), so it stays blocked. `why` is the
    /// switch's own sentence; the person can retry.
    case outputStillBlocked(why: String)
}

final class RoutingCoordinator {

    /// The outcome of a switch that went ahead or had nothing to do. A switch
    /// that did not happen throws instead, so it cannot be mistaken for one.
    enum SwitchResult: Equatable {
        case alreadyInMode
        case switched(to: PlaybackMode)
    }

    private let store: PlaybackModeStore
    /// Builds the client for a source-backed mode: the Mac's own SpanDAC for
    /// `.source`, the paired network link for `.networkSource`.
    private let makeSource: (PlaybackMode) -> SourceAppClient

    /// Where the DATA selection lives.
    private enum DataAxis {
        /// Production (through `live`) and every coordinator given a store:
        /// data.json, read once at init.
        case stored(DataProviderStore)
        /// A coordinator composed WITHOUT a data store, by the inits that
        /// predate the data axis. It keeps the single selection it was built
        /// with: data follows the output, so there is nothing to accept,
        /// decline or stop, and no blocked state. Production never composes
        /// one (`live` always passes a store); tests that predate the axis do.
        case followsOutput
    }
    private let dataAxis: DataAxis
    /// Builds the DATA client: always SpanDAC on this Mac, never a network
    /// SpanDAC, whatever the output is.
    private let makeDataClient: () -> SourceAppClient

    /// Starts SpanDAC on this Mac. Held so the whole process shares one
    /// starter, and with it one launch attempt.
    let macStarter: MacSpanDACStarting

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
    /// The client built for `current`, and the mode it was built for, so a
    /// switch between two SpanDACs never reuses the other's client.
    private var source: (mode: PlaybackMode, client: SourceAppClient)?
    /// The data client, built on first use.
    private var dataSource: SourceAppClient?
    /// The one accepted data state (`spandac_mac` AND `accepted`), in memory.
    private var accepted: Bool
    private var ceremonyState: SwitchCeremonyState
    private var reachedBoundary: (() -> Void)?

    /// Slice 3 Part 2, D3. Starts at 0; incremented exactly once per
    /// COMMITTED switch (never on `alreadyInMode`, a refused switch — readiness,
    /// an unconfirmed pause, a failed queue drop, a failed save — or a
    /// foreign-process mismatch caught by `underOutputLock`). In-process only,
    /// like `mode` itself: another TUI process's switch is not seen by this
    /// one's epoch (true today).
    private var _epoch = 0

    /// C-EPOCH. Starts at 0; incremented exactly once per COMMITTED
    /// `acceptSpanDACData` or `stopUsingSpanDACData`, never by an output switch.
    private var _dataEpoch = 0

    /// A unique key per instance. `ObjectIdentifier.hashValue` is not
    /// guaranteed unique, so it cannot name "this coordinator" (Codex, 11:47).
    private let reentryKey = "RoutingCoordinator.\(UUID().uuidString)"

    /// Reads BOTH persisted selections ONCE: mode.json for the output and
    /// data.json for the data source. From here on the in-memory values are
    /// the truth for the life of the process; only a switch changes the
    /// output, and only accept or stop changes the data. A read never writes.
    ///
    /// `dataStore` has no default: a test names its own temp file, because
    /// `HOME=` does not isolate `~/.config/music`.
    init(store: PlaybackModeStore,
         surface: InvocationSurface,
         outputLock: OutputLock? = nil,
         dataStore: DataProviderStore,
         makeSourceFor: @escaping (PlaybackMode) -> SourceAppClient,
         makeDataClient: @escaping () -> SourceAppClient,
         starter: MacSpanDACStarting) {
        self.store = store
        self.surface = surface
        self.makeSource = makeSourceFor
        self.outputLock = outputLock
        self.current = store.mode()
        self.dataAxis = .stored(dataStore)
        self.makeDataClient = makeDataClient
        self.macStarter = starter
        // The ONLY accepted state is both values together (C-AXES); anything
        // else is open data, with whatever ceremony state it names.
        let read = dataStore.read()
        self.accepted = read.data == .spandacMac && read.ceremony == .accepted
        self.ceremonyState = read.ceremony
    }

    /// The composition that predates the data axis: data follows the output
    /// (see `DataAxis.followsOutput`). The data client is the Mac's own, from
    /// the same factory.
    init(store: PlaybackModeStore,
         surface: InvocationSurface,
         makeSourceFor: @escaping (PlaybackMode) -> SourceAppClient,
         outputLock: OutputLock? = nil) {
        self.store = store
        self.surface = surface
        self.makeSource = makeSourceFor
        self.outputLock = outputLock
        self.current = store.mode()
        self.dataAxis = .followsOutput
        self.makeDataClient = { makeSourceFor(.source) }
        self.macStarter = NeverStartsMacSpanDAC()
        self.accepted = false
        self.ceremonyState = .neverShown
    }

    /// `makeSource` builds the Mac's own SpanDAC client. A SpanDAC on the
    /// network is refused as not paired: a coordinator composed this way was
    /// never given a way to reach one, and it must not guess (fail closed).
    convenience init(store: PlaybackModeStore,
                     surface: InvocationSurface,
                     makeSource: @escaping () -> SourceAppClient,
                     outputLock: OutputLock? = nil) {
        self.init(store: store, surface: surface, makeSourceFor: { mode in
            mode.networkSourceID == nil ? makeSource() : .failing(.notPaired)
        }, outputLock: outputLock)
    }

    /// The composition both processes use: the TUI once at launch with `.tui`,
    /// each CLI command once per invocation with `.cli`, so the CLI obeys the
    /// same selections the Output tab made (Codex B2) while 12.14 still tells
    /// the two surfaces apart. It always carries the output lock and data.json
    /// beside the store's mode.json, so a temp store gets a temp lock and a
    /// temp data file; the data client is SpanDAC on this Mac, started by
    /// `starter` when it is needed.
    static func live(store: PlaybackModeStore = PlaybackModeStore(), surface: InvocationSurface,
                     starter: MacSpanDACStarting = liveMacSpanDACStarter()) -> RoutingCoordinator {
        RoutingCoordinator(store: store, surface: surface, outputLock: OutputLock(path: store.lockPath),
                           dataStore: DataProviderStore(beside: store),
                           makeSourceFor: { SourceAppClient.selected(for: $0) },
                           makeDataClient: { SourceAppClient.macData(starter: starter) },
                           starter: starter)
    }

    /// A client for `mode`, built by this coordinator's factory. CONSTRUCTION
    /// only, outside the ordering boundary: for a caller that reads (the Now
    /// poller, a scene's provider) and has already decided from `mode` that a
    /// source is selected. Routing an ACTION still goes through `perform`.
    func client(for mode: PlaybackMode) -> SourceAppClient {
        makeSource(mode)
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

    /// C-EPOCH. Moves only when the data source changes.
    var dataEpoch: Int {
        state.lock(); defer { state.unlock() }
        return _dataEpoch
    }

    /// Both epochs, read together.
    var stamp: (epoch: Int, dataEpoch: Int) {
        state.lock(); defer { state.unlock() }
        return (_epoch, _dataEpoch)
    }

    /// What the two selections mean together now (C-REPAIR): a SpanDAC
    /// output with no accepted data is `outputBlocked`.
    var selection: EffectiveSelection {
        state.lock(); defer { state.unlock() }
        return composedSelection()
    }

    /// Where music data comes from now. Open while blocked.
    var data: DataProviderSelection {
        switch selection {
        case .consistent(let data, _): return data
        case .outputBlocked: return .open
        }
    }

    /// The switch screen's state, as read at init and changed since by this
    /// coordinator. A coordinator without a data store has none to show.
    var ceremony: SwitchCeremonyState {
        state.lock(); defer { state.unlock() }
        return ceremonyState
    }

    /// The DATA client: SpanDAC on this Mac. CONSTRUCTION only, outside the
    /// ordering boundary, for a caller that has already decided from
    /// `selection` that data is SpanDAC's; routing a read still goes through
    /// `choose`. Built once.
    func dataClient() -> SourceAppClient {
        state.lock()
        let cached = dataSource
        state.unlock()
        if let cached { return cached }
        let made = makeDataClient()
        state.lock(); dataSource = made; state.unlock()
        return made
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
    ///
    /// The call sites that predate the data axis use this form. Their
    /// `musicApp` body is the SHIPPED one, so it runs only where the matrix
    /// names the shipped path: a SpanDAC row on the MusicTUI output, which
    /// needs the path its origin names, refuses here.
    func perform(_ action: MusicTUIAction,
                 musicApp: () throws -> Void,
                 source: (SourceAppClient) throws -> Void,
                 unaffected: () throws -> Void) throws {
        try perform(action, expecting: nil, origin: nil,
                    musicApp: { path in
                        guard path == .shipped else { throw ActionError(message: pickASpanDACOutput) }
                        try musicApp()
                    },
                    source: source, unaffected: unaffected)
    }

    /// Runs exactly one branch for `action`, routed on both axes now.
    ///
    /// - `expecting`: the stamp the caller's READ was made under. Checked
    ///   inside the boundary before any branch runs: if either epoch moved,
    ///   nothing runs and it throws `sourceChangedNothingPlayed`. Nil only for
    ///   an action with no earlier read.
    /// - `origin`: where the row being played came from. It picks the
    ///   MusicTUI-output path with SpanDAC data (library to `.handoff`,
    ///   catalogue to `.add`, a Discover container to `.addContainer`), and
    ///   refuses a row whose data source has changed since it was read.
    /// - `.musicApp` runs `musicApp` with the path to take; the caller supplies
    ///   every body. `.source` runs `source` with the OUTPUT client, except a
    ///   pure read, which gets the DATA client (SpanDAC on this Mac): a read
    ///   has no output. Nothing falls back on either axis.
    func perform(_ action: MusicTUIAction,
                 expecting: (epoch: Int, dataEpoch: Int)?,
                 origin: PlayOrigin? = nil,
                 musicApp: (MusicTUIPlayPath) throws -> Void,
                 source: (SourceAppClient) throws -> Void,
                 unaffected: () throws -> Void) throws {
        try exclusively {
            if let expecting, expecting != stamp {
                throw ActionError(message: sourceChangedNothingPlayed)
            }
            let now = selection
            let routed = routeAction(action, selection: now, from: surface)
            if case .refused(let why) = routed.sound { throw ActionError(message: why) }
            try refuseAStaleOrigin(origin, for: action, in: now)
            switch routed.sound {
            case .unaffected:
                try unaffected()
            case .source:
                try source(action.readsMusicData && routed.data == .spandacMac ? dataClient() : sourceClient())
            case .musicApp:
                try musicApp(try musicTUIPath(for: action, origin: origin, in: now))
            case .refused(let why):
                throw ActionError(message: why)
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
    ///
    /// **Routed by the DATA axis.** Open data builds the `musicApp` provider
    /// (MusicTUI's own data); SpanDAC data hands `source` the DATA client,
    /// SpanDAC on this Mac, never a network SpanDAC. An action that reads no
    /// data keeps its sound route, as before. The choice carries both epochs.
    func choose<Provider>(_ action: MusicTUIAction,
                          musicApp: () throws -> Provider,
                          source: (SourceAppClient) throws -> Provider) throws -> ProviderChoice<Provider> {
        try exclusively {
            let now = selection
            let routed = routeAction(action, selection: now, from: surface)
            func choice(_ provider: Provider) -> ProviderChoice<Provider> {
                ProviderChoice(provider: provider, epoch: epoch, mode: mode, dataEpoch: dataEpoch, selection: now)
            }
            switch routed.data {
            case .open:
                return choice(try musicApp())
            case .spandacMac:
                return choice(try source(dataClient()))
            case .refused(let why):
                throw ActionError(message: why)
            case .none:
                switch routed.sound {
                case .musicApp:
                    return choice(try musicApp())
                case .source:
                    return choice(try source(sourceClient()))
                case .unaffected:
                    throw ActionError(message: "Internal error: \(action) has no provider to choose")
                case .refused(let why):
                    throw ActionError(message: why)
                }
            }
        }
    }

    // MARK: - The data source (C-EPOCH, C-CEREMONY, C-REPAIR)

    /// Makes SpanDAC on this Mac MusicTUI's data source: the switch screen's
    /// Enter. Inside the ordering boundary and the output lock, like a switch.
    ///
    /// Refuses unless SpanDAC on this Mac is ready (`readiness` is read HERE,
    /// inside the boundary). A save that fails changes nothing. On commit,
    /// `dataEpoch` moves once and the output is untouched: a blocked stored
    /// SpanDAC output becomes live.
    @discardableResult
    func acceptSpanDACData(readiness: () -> SourceReadiness) throws -> DataSwitchResult {
        try exclusively { try underOutputLock {
            let store = try dataStore()
            if accepted { return .alreadySelected }
            let ready = readiness()
            // CHOSEN wording, like the switch's own.
            guard ready == .ready else {
                throw ActionError(message: "SpanDAC on this Mac is \(ready.label); MusicTUI is still using its own music data.")
            }
            guard store.accept() else {
                throw ActionError(message: "Couldn't save the switch to SpanDAC; MusicTUI is still using its own music data.")
            }
            state.lock(); accepted = true; ceremonyState = .accepted; _dataEpoch += 1; state.unlock()
            return .switched(to: .spandacMac)
        } }
    }

    /// The switch screen's Esc: records that the person said not now. Data
    /// stays open; `dataEpoch` does not move, because nothing was switched.
    func declineSpanDACData() throws {
        try exclusively {
            let store = try dataStore()
            guard !accepted else { return }
            guard store.decline() else {
                throw ActionError(message: "Couldn't save your answer; MusicTUI may ask again.")
            }
            state.lock(); ceremonyState = .declined; state.unlock()
        }
    }

    /// "Stop using SpanDAC for music data" (Anthony, 12:19): only a person's
    /// answer calls this. Nothing switches by itself.
    ///
    /// If the output is a SpanDAC (live, or blocked), the normal switch to
    /// MusicTUI runs first, through the same transaction as `switchMode`, with
    /// data still as it was: the outgoing SpanDAC is paused and its queue
    /// dropped. `pauseOutgoing` follows `switchMode`'s evidence rule: a
    /// reported paused, stopped or idle status, or independently established
    /// absence (for SpanDAC on this Mac: not running per LaunchServices AND no
    /// socket). That pause is the one SpanDAC client C-REPAIR allows before
    /// data is accepted, because it can only silence.
    ///
    /// Then data returns to open (`stopUsingSpanDAC()`, ceremony declined) and
    /// `dataEpoch` moves once. If the output could not be switched, data still
    /// returns to open and the output stays blocked; the result says why and
    /// the person can retry.
    @discardableResult
    func stopUsingSpanDACData(pauseOutgoing: (PlaybackMode) throws -> Bool,
                              dropQueue: (PlaybackMode) throws -> Void) throws -> StopUsingSpanDACResult {
        try exclusively { try underOutputLock {
            let store = try dataStore()
            let outgoing = mode
            guard accepted || outgoing.usesSource else { return .alreadyOpen }

            var outputProblem: String?
            var outputMoved = false
            if outgoing.usesSource {
                do {
                    _ = try commitOutputSwitch(to: .musicApp, readiness: { .ready },
                                               pauseOutgoing: pauseOutgoing, dropQueue: dropQueue)
                    outputMoved = true
                } catch let error as ActionError {
                    outputProblem = error.message
                }
            }

            guard store.stopUsingSpanDAC() else {
                // CHOSEN wording: say what did change.
                var why = "Couldn't save the change of music source"
                if outputMoved { why += "; Output is now \(name(.musicApp))" }
                why += accepted ? ", still using SpanDAC for music data." : "."
                if let outputProblem { why += " \(outputProblem)." }
                throw ActionError(message: why)
            }
            state.lock(); accepted = false; ceremonyState = .declined; _dataEpoch += 1; state.unlock()
            if let outputProblem { return .outputStillBlocked(why: outputProblem) }
            return .stopped
        } }
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
    ///
    /// **The data axis (C-REPAIR).** A SpanDAC output needs accepted data:
    /// switching to one without it refuses before anything is touched. A
    /// blocked stored output is left only by accepting or by stopping using
    /// SpanDAC, never by a plain switch.
    func switchMode(to target: PlaybackMode,
                    readiness: () -> SourceReadiness,
                    pauseOutgoing: (PlaybackMode) throws -> Bool,
                    dropQueue: (PlaybackMode) throws -> Void) throws -> SwitchResult {
        try exclusively { try underOutputLock {
            let outgoing = mode
            guard target != outgoing else { return .alreadyInMode }
            if case .stored = dataAxis, !accepted {
                if outgoing.usesSource { throw ActionError(message: finishSwitchingToSpanDAC) }
                if target.usesSource { throw ActionError(message: switchMusicTUIToSpanDACFirst) }
            }
            return try commitOutputSwitch(to: target, readiness: readiness,
                                          pauseOutgoing: pauseOutgoing, dropQueue: dropQueue)
        } }
    }

    // MARK: - private

    /// The switch transaction itself (rule 4, ruling 12.3), for a caller that
    /// already holds `order` and the output lock.
    private func commitOutputSwitch(to target: PlaybackMode,
                                    readiness: () -> SourceReadiness,
                                    pauseOutgoing: (PlaybackMode) throws -> Bool,
                                    dropQueue: (PlaybackMode) throws -> Void) throws -> SwitchResult {
        let outgoing = mode
        guard target != outgoing else { return .alreadyInMode }

        let ready = target.usesSource ? readiness() : .ready
        guard outputModeSelectable(target, readiness: ready) else {
            // A SpanDAC on the network's reasons are whole sentences.
            if target.networkSourceID != nil {
                let why = ready.label.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                throw ActionError(message: "\(why). Still using \(name(outgoing)).")
            }
            throw ActionError(message: "SpanDAC on this Mac is \(ready.label); still using \(name(outgoing))")
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
    }

    /// `selection` for the in-memory values. The caller holds `state`.
    private func composedSelection() -> EffectiveSelection {
        switch dataAxis {
        case .followsOutput:
            return .consistent(data: current.usesSource ? .spandacMac : .open, output: current)
        case .stored:
            if accepted { return .consistent(data: .spandacMac, output: current) }
            return current.usesSource ? .outputBlocked(stored: current) : .consistent(data: .open, output: current)
        }
    }

    private func dataStore() throws -> DataProviderStore {
        guard case .stored(let store) = dataAxis else {
            throw ActionError(message: "Internal error: this coordinator has no data store")
        }
        return store
    }

    /// C-MATRIX's origin rule, for a choose-and-play: a row read under open
    /// data never plays once data is SpanDAC's, and a SpanDAC row never plays
    /// once data is open again. The row's origin decides, never its id.
    private func refuseAStaleOrigin(_ origin: PlayOrigin?, for action: MusicTUIAction,
                                    in selection: EffectiveSelection) throws {
        guard let origin, action.playsChosenMusic else { return }
        let spandacData: Bool
        if case .consistent(.spandacMac, _) = selection { spandacData = true } else { spandacData = false }
        switch origin {
        case .openData(let number) where spandacData:
            if surface == .cli, let number { throw ActionError(message: resultFromBeforeSpanDACSwitch(number)) }
            throw ActionError(message: listFromBeforeSpanDACSwitch)
        case .spandacLibrary, .spandacCatalogue, .spandacDiscoverContainer:
            if !spandacData { throw ActionError(message: sourceChangedNothingPlayed) }
        case .openData:
            break
        }
    }

    /// Which body the `.musicApp` branch runs. Everything is the shipped body
    /// except a choose-and-play on the MusicTUI output with SpanDAC data,
    /// whose path is its row's origin's, and a station there, which plays by
    /// URL. No origin, there, refuses: it would be a guess.
    private func musicTUIPath(for action: MusicTUIAction, origin: PlayOrigin?,
                              in selection: EffectiveSelection) throws -> MusicTUIPlayPath {
        guard case .consistent(.spandacMac, .musicApp) = selection, action.playsChosenMusic else { return .shipped }
        if action == .radioStationPlay { return .stationURL }
        switch origin {
        case .spandacLibrary?: return .handoff
        case .spandacCatalogue?: return .add
        case .spandacDiscoverContainer?: return .addContainer
        case .openData?, nil: throw ActionError(message: pickASpanDACOutput)
        }
    }

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
    /// deadlock. `order` is already held, so two clients are never built. The
    /// cache is per mode: after a switch from one SpanDAC to another, the old
    /// one's client is never handed out.
    private func sourceClient() -> SourceAppClient {
        let now = mode
        state.lock()
        let cached = source
        state.unlock()
        if let cached, cached.mode == now { return cached.client }
        let made = makeSource(now)
        state.lock(); source = (now, made); state.unlock()
        return made
    }

    /// TEST SEAM. Called on the entering thread just before it waits for the
    /// ordering boundary, so a test can prove a competing call has reached the
    /// lock instead of sleeping and hoping (Codex, 11:47).
    func onReachingBoundary(_ hook: (() -> Void)?) {
        state.lock(); reachedBoundary = hook; state.unlock()
    }

    /// The name a PERSON reads. Ruling 12.15 (2026-09-15): the user-facing
    /// output is **SpanDAC**; the app and the internal components keep the name
    /// MusicTUI Source. Type names are deliberately not renamed with it. The
    /// non-SpanDAC output is **MusicTUI** everywhere a person reads (Anthony,
    /// 2026-09-28 12:10); `.musicApp` keeps its internal name.
    private func name(_ mode: PlaybackMode) -> String {
        switch mode {
        case .musicApp: return musicTUIOutputName
        case .source:   return "SpanDAC on this Mac"
        case .networkSource: return "SpanDAC"
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
