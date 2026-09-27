// SpanDACs on the network, as the Output tab shows them (the pairing design,
// sections 4.2 and 4.3).
//
// Three sources, merged into one row per SpanDAC:
// - what Bonjour sees (`_spandac._tcp`): a HINT, unauthenticated, shown as
//   "seen on this network" and never as ready;
// - what `paired.json` holds: the SpanDACs this Mac can authenticate to;
// - what an authenticated `slice.status` over the paired link answered, asked
//   once when the tab opens (readiness is a question you ask on opening the
//   tab, not a heartbeat).
//
// The browser runs only while the Output tab is open, or while a pairing is
// waiting for the iPad's window: `touch()` holds it for two seconds.
import Foundation
import Network
import SystemConfiguration

/// One service Bonjour reported, with its decoded TXT record.
struct SpanDACSighting: Equatable {
    let serviceName: String
    let txt: SpanDACTXT
    var sourceID: String { txt.sourceID }
}

protocol SpanDACBrowsing: AnyObject {
    /// Starts browsing; `results` gets the full current set on every change,
    /// on a private queue.
    func start(_ results: @escaping ([SpanDACSighting]) -> Void)
    func stop()
}

/// `NWBrowser` for `_spandac._tcp` with TXT records.
final class SpanDACBonjourBrowser: SpanDACBrowsing {
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "spandac.browse")

    func start(_ results: @escaping ([SpanDACSighting]) -> Void) {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_spandac._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { found, _ in
            var byID: [String: SpanDACSighting] = [:]
            for result in found {
                guard case .service(let name, _, _, _) = result.endpoint,
                      case .bonjour(let record) = result.metadata else { continue }
                let txt = Dictionary(record.dictionary.map { ($0.key.lowercased(), $0.value) },
                                     uniquingKeysWith: { first, _ in first })
                guard let decoded = SpanDACTXT(txt) else { continue }
                // One service can be reported once per interface; a window
                // that is open on any report counts.
                if let seen = byID[decoded.sourceID], seen.txt.pairingPort != nil { continue }
                byID[decoded.sourceID] = SpanDACSighting(serviceName: name, txt: decoded)
            }
            results(Array(byID.values))
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}

/// A SpanDAC row, ready to draw.
struct SpanDACOutputRow: Equatable {
    let sourceID: String
    let name: String
    let paired: Bool
    /// The note beside the name.
    let note: String
    /// Only an authenticated, ready answer makes a row selectable.
    let ready: Bool
}

/// Merges the three sources into rows: paired SpanDACs first, then ones seen
/// but not paired, each group by name. `selected` keeps a row for the chosen
/// SpanDAC even when it is neither paired nor seen, so the selection never
/// disappears from the screen.
func spandacOutputRows(paired: [SpanDACPairRecord], seen: [SpanDACSighting],
                       probes: [String: SpanDACOutputs.Probe], pairing: SpanDACOutputs.PairingState?,
                       forgetPrompt: String?, selected: String?) -> [SpanDACOutputRow] {
    let seenByID = Dictionary(seen.map { ($0.sourceID, $0) }, uniquingKeysWith: { first, _ in first })
    var rows: [SpanDACOutputRow] = []
    func note(for id: String, paired: Bool) -> (String, Bool) {
        if forgetPrompt == id { return ("forget? y / n", false) }
        if let pairing, pairing.sourceID == id { return (pairing.note, false) }
        guard paired else { return ("not paired · Enter to pair", false) }
        switch probes[id] {
        case .ready?: return ("ready", true)
        case .unavailable(let why)?: return (why, false)
        case .checking?, nil: return ("checking…", false)
        }
    }
    for record in paired.sorted(by: { ($0.sourceName, $0.sourceID) < ($1.sourceName, $1.sourceID) }) {
        let (text, ready) = note(for: record.sourceID, paired: true)
        rows.append(SpanDACOutputRow(sourceID: record.sourceID, name: record.sourceName, paired: true, note: text, ready: ready))
    }
    let pairedIDs = Set(paired.map(\.sourceID))
    for sighting in seen.filter({ !pairedIDs.contains($0.sourceID) })
        .sorted(by: { ($0.txt.name, $0.sourceID) < ($1.txt.name, $1.sourceID) }) {
        let (text, ready) = note(for: sighting.sourceID, paired: false)
        rows.append(SpanDACOutputRow(sourceID: sighting.sourceID, name: sighting.txt.name, paired: false, note: text, ready: ready))
    }
    if let selected, !rows.contains(where: { $0.sourceID == selected }) {
        let name = seenByID[selected]?.txt.name ?? "SpanDAC"
        rows.append(SpanDACOutputRow(sourceID: selected, name: name, paired: false,
                                     note: "not paired · not found on this network", ready: false))
    }
    return rows
}

/// The Output tab's SpanDACs on the network: discovery, readiness probes,
/// pairing and forgetting. Background work lands in state guarded by one
/// lock; the scene reads `rows` on its own loop and asks `tick()` whether
/// anything changed.
final class SpanDACOutputs {

    enum Probe: Equatable {
        case checking
        case ready
        case unavailable(String)
    }

    struct PairingState: Equatable {
        enum Phase: Equatable {
            /// Waiting for the iPad to open its pairing window.
            case waitingForWindow
            case connecting
            /// The key confirmation is running. MusicTUI's own side answered
            /// automatically; only the device's person still has something to
            /// do, by tapping Allow there.
            case confirming
        }
        let sourceID: String
        let name: String
        var phase: Phase

        var note: String {
            switch phase {
            case .waitingForWindow: return "pairing · tap Pair with MusicTUI on \(name)"
            case .connecting: return "pairing…"
            case .confirming: return "pairing · tap Allow on \(name)"
            }
        }
    }

    /// How long a pairing waits for the iPad's window (section 4.3).
    static let windowWait: TimeInterval = 120
    /// How long the browser keeps running after the last `touch()`.
    static let browseLease: TimeInterval = 2

    private let pairs: SpanDACPairedStore
    private let browser: SpanDACBrowsing
    private let makeClient: (String) -> SourceAppClient
    private let driver: SpanDACPairingDriving
    private let registry: SpanDACLinkRegistry
    private let post: (String, Bool, TimeInterval) -> Void
    private let controllerName: String
    private let now: () -> Date

    private let lock = NSLock()
    private var sightings: [SpanDACSighting] = []
    private var probes: [String: Probe] = [:]
    private var pairing: PairingState?
    private var pairingHandle: SpanDACPairingHandle?
    private var pairingDeadline = Date.distantPast
    private var forgetPrompt: String?
    private var version = 0
    private var seenVersion = 0
    private var lastTouch = Date.distantPast
    private var browsing = false
    /// `paired.json` as last read: on opening the tab, and after this
    /// process pairs or forgets. Not re-read on every frame.
    private var paired: [SpanDACPairRecord] = []

    init(pairs: SpanDACPairedStore = SpanDACPairedStore(),
         browser: SpanDACBrowsing = SpanDACBonjourBrowser(),
         makeClient: @escaping (String) -> SourceAppClient,
         driver: SpanDACPairingDriving = SpanDACNetworkPairing(),
         registry: SpanDACLinkRegistry = .shared,
         controllerName: String = SpanDACOutputs.thisMacName(),
         now: @escaping () -> Date = Date.init,
         post: @escaping (String, Bool, TimeInterval) -> Void) {
        self.pairs = pairs
        self.browser = browser
        self.makeClient = makeClient
        self.driver = driver
        self.registry = registry
        self.controllerName = controllerName
        self.now = now
        self.post = post
    }

    /// "MusicTUI on <this Mac's name>", fitted to the protocol's 64 bytes.
    static func thisMacName() -> String {
        let computer = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
        return SpanDACPair.fittedName("MusicTUI on \(computer)") ?? "MusicTUI"
    }

    // MARK: - The scene's side

    /// The rows to draw now. `selectedSourceID` is the network SpanDAC the
    /// Output is set to, if any.
    func rows(selected selectedSourceID: String?) -> [SpanDACOutputRow] {
        lock.lock(); defer { lock.unlock() }
        return spandacOutputRows(paired: paired, seen: sightings, probes: probes, pairing: pairing,
                                 forgetPrompt: forgetPrompt, selected: selectedSourceID)
    }

    /// Re-reads `paired.json`.
    private func reloadPairs() {
        let fresh = pairs.pairs()
        lock.lock(); paired = fresh; version += 1; lock.unlock()
    }

    /// True once per change since the last call.
    func tick() -> Bool {
        lock.lock(); defer { lock.unlock() }
        expireLocked()
        let changed = version != seenVersion
        seenVersion = version
        return changed
    }

    /// Keeps the browser running for another lease; the scene calls this on
    /// every tick while the Output tab is open.
    func touch() {
        lock.lock()
        lastTouch = now()
        let start = !browsing
        browsing = true
        lock.unlock()
        guard start else { return }
        browser.start { [weak self] found in
            guard let self else { return }
            self.lock.lock()
            self.sightings = found
            self.version += 1
            let pending = self.pairing
            self.lock.unlock()
            if let pending, pending.phase == .waitingForWindow { self.startPairingIfWindowOpen(pending.sourceID) }
        }
        scheduleLeaseCheck()
    }

    private func scheduleLeaseCheck() {
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.browseLease) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let idle = self.now().timeIntervalSince(self.lastTouch) >= Self.browseLease && self.pairing == nil
            if idle { self.browsing = false }
            self.lock.unlock()
            if idle { self.browser.stop() } else { self.scheduleLeaseCheck() }
        }
    }

    /// The tab was (re)opened: ask each paired SpanDAC how it is, once.
    func activated() {
        reloadPairs()
        if let problem = pairs.problem() { post(problem, true, 6) }
        lock.lock(); let ids = paired.map(\.sourceID); lock.unlock()
        for id in ids { probe(id) }
    }

    /// One authenticated status read, off the input thread.
    func probe(_ sourceID: String) {
        lock.lock(); probes[sourceID] = .checking; version += 1; lock.unlock()
        let client = makeClient(sourceID)
        DispatchQueue.global().async { [weak self] in
            let result: Probe
            do {
                let readiness = try client.control.status().readiness
                result = readiness == .ready ? .ready : .unavailable(readiness.label)
            } catch SourceAppError.link(let failure) {
                result = .unavailable(failure.note)
            } catch {
                result = .unavailable(SourceReadiness.from(error).label)
            }
            guard let self else { return }
            self.lock.lock(); self.probes[sourceID] = result; self.version += 1; self.lock.unlock()
        }
    }

    /// A y/n is being asked (only a forget to confirm now: pairing's own
    /// confirmation is automatic and asks the person nothing).
    var awaitingAnswer: Bool {
        lock.lock(); defer { lock.unlock() }
        return forgetPrompt != nil
    }

    var isPairing: Bool {
        lock.lock(); defer { lock.unlock() }
        return pairing != nil
    }

    // MARK: - Pairing

    /// Enter on a SpanDAC that is not paired (section 4.3, step 1).
    func pair(_ sourceID: String) {
        lock.lock()
        guard pairing == nil else { lock.unlock(); return }
        let name = sightings.first { $0.sourceID == sourceID }?.txt.name ?? "SpanDAC"
        pairing = PairingState(sourceID: sourceID, name: name, phase: .waitingForWindow)
        pairingDeadline = now().addingTimeInterval(Self.windowWait)
        forgetPrompt = nil
        version += 1
        lock.unlock()
        post("Open SpanDAC on \(name) and tap Pair with MusicTUI.", false, Self.windowWait)
        startPairingIfWindowOpen(sourceID)
    }

    /// Connects once the iPad's TXT record says its window is open.
    private func startPairingIfWindowOpen(_ sourceID: String) {
        lock.lock()
        guard var state = pairing, state.sourceID == sourceID, state.phase == .waitingForWindow,
              let sighting = sightings.first(where: { $0.sourceID == sourceID }),
              let port = sighting.txt.pairingPort else { lock.unlock(); return }
        state.phase = .connecting
        pairing = state
        version += 1
        lock.unlock()

        let controllerID: String
        do {
            controllerID = try pairs.controllerID()
        } catch {
            finishPairing(.failure(.notSaved((error as? SpanDACPairedStoreError)?.message ?? "\(error)")))
            return
        }
        let serviceName = sighting.serviceName
        let store = pairs
        let handle = driver.begin(serviceName: serviceName, port: port, controllerID: controllerID,
                                  controllerName: controllerName,
                                  save: { result in
            do {
                try store.save(SpanDACPairRecord(sourceID: result.sourceID, sourceName: result.sourceName,
                                                 pskID: result.pskID, pairKey: result.pairKey,
                                                 serviceName: serviceName, pairedAt: Date()))
                return nil
            } catch {
                return (error as? SpanDACPairedStoreError)?.message ?? "\(error)"
            }
        }, events: { [weak self] event in self?.handle(event) })
        lock.lock(); pairingHandle = handle; lock.unlock()
    }

    private func handle(_ event: SpanDACPairingEvent) {
        switch event {
        case .code:
            // The key confirmation the wire protocol runs is unchanged; only
            // who answers "matches" does. MusicTUI answers its own side at
            // once, with no prompt — only the device's person still taps
            // anything, via its own Allow / Don't allow.
            pairingHandle?.answer(matches: true)
        case .confirming:
            lock.lock()
            let name = pairing?.name ?? "SpanDAC"
            pairing?.phase = .confirming
            version += 1
            lock.unlock()
            post("Tap Allow on \(name).", false, SpanDACPairingController.confirmTimeout)
        case .finished(let result):
            finishPairing(result)
        }
    }

    private func finishPairing(_ result: Result<SpanDACPairResult, SpanDACPairFailure>) {
        lock.lock()
        pairing = nil
        pairingHandle = nil
        version += 1
        lock.unlock()
        switch result {
        case .success(let pair):
            reloadPairs()
            post("Paired with \(pair.sourceName).", false, 4)
            probe(pair.sourceID)
        case .failure(let failure):
            post(failure.sentence, true, 6)
        }
    }

    /// The person's y or n to "Forget …?". Pairing no longer asks anything
    /// here: MusicTUI answers its own confirmation automatically.
    func answer(_ yes: Bool) {
        lock.lock()
        guard let id = forgetPrompt else { lock.unlock(); return }
        forgetPrompt = nil
        version += 1
        lock.unlock()
        if yes { forget(id) } else { post("Nothing was forgotten.", false, 3) }
    }

    /// Esc: drop a pending question or a pairing in progress.
    @discardableResult
    func cancel() -> Bool {
        lock.lock()
        if forgetPrompt != nil {
            forgetPrompt = nil
            version += 1
            lock.unlock()
            post("Nothing was forgotten.", false, 3)
            return true
        }
        guard pairing != nil else { lock.unlock(); return false }
        let handle = pairingHandle
        let waiting = pairing?.phase == .waitingForWindow
        lock.unlock()
        if let handle { handle.cancel() }
        if waiting || handle == nil { finishPairing(.failure(.cancelled)) }
        return true
    }

    private func expireLocked() {
        guard let state = pairing, state.phase == .waitingForWindow, now() >= pairingDeadline else { return }
        pairing = nil
        version += 1
        DispatchQueue.global().async { [weak self] in
            self?.post("SpanDAC on \(state.name) did not open pairing; nothing was paired.", true, 6)
        }
    }

    // MARK: - Forgetting

    /// `f` on a paired SpanDAC: ask first (section 4.3, step 4).
    func askToForget(_ sourceID: String) {
        lock.lock()
        guard pairing == nil, let record = paired.first(where: { $0.sourceID == sourceID }) else {
            lock.unlock(); return
        }
        forgetPrompt = sourceID
        version += 1
        lock.unlock()
        post("Forget \(record.sourceName)? y / n", false, 30)
    }

    /// Deletes this Mac's copy of the pair, then cancels every connection
    /// this process has open to it. The iPad's own list is the iPad's: this
    /// does not remove the Mac there.
    func forget(_ sourceID: String) {
        let name = pairs.pair(for: sourceID)?.sourceName ?? "SpanDAC"
        do {
            try pairs.forget(sourceID: sourceID)
        } catch {
            post((error as? SpanDACPairedStoreError)?.message ?? "\(error)", true, 6)
            return
        }
        registry.cancelAll(sourceID)
        lock.lock(); probes[sourceID] = nil; version += 1; lock.unlock()
        reloadPairs()
        post("Forgot \(name). Remove this Mac in SpanDAC on \(name) too.", false, 5)
    }
}
