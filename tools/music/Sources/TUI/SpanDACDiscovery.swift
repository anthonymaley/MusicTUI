// SpanDACs on the network, as the Output tab shows them.
//
// Three sources, merged into one row per SpanDAC, keyed by `sourceID`:
// - what Bonjour sees (`_spandac._tcp`): a HINT, unauthenticated and
//   eventually consistent, shown as "seen on this network" and never as
//   ready. `pair=1` + `pairport` is an invitation to try pairing, never proof
//   the device will accept;
// - what `paired.json` holds: the SpanDACs this Mac can authenticate to;
// - what an authenticated `slice.status` over the paired link answered: asked
//   when the tab opens, then again every `reprobeInterval` while the tab is
//   shown (the scene touches every tick), one probe in flight per SpanDAC,
//   none while the tab is hidden.
//
// A TLS refusal on a probe never deletes anything: the alert is not
// authenticated. An unknown identity shows the row as forgotten, a secret
// mismatch as broken, and the pair stays until `f` Forget or a re-pair
// replaces it.
//
// The browser runs only while the Output tab is open, or while a pairing is
// running: `touch()` holds it for two seconds.
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
                // One service can be reported once per interface; a report
                // that advertises pairing on any interface counts.
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
    /// The short note beside the name (kept filled; the scene draws from
    /// `state`).
    let note: String
    /// Only an authenticated, ready answer makes a row selectable. Always
    /// exactly `state == .ready`.
    let ready: Bool
    var state: SpanDACRowState = .checking
    /// What the SpanDAC last said about its output, from an authenticated
    /// answer; nil when it has not answered or predates the field.
    var output: SourceOutputInfo? = nil
}

/// The row words for the device's three "not now" refusals (C-TXT).
enum SpanDACNotPairableNow {
    static let busy = "pairing with another Mac  try again in a moment"
    static let tooMany = "asked this Mac to wait  try again shortly"
    static let closed = "not ready to pair  open SpanDAC on it"

    /// The row words for a failure that means "not now", or nil for any other.
    static func reason(for failure: SpanDACPairFailure) -> String? {
        switch failure {
        case .busy: return busy
        case .tooMany: return tooMany
        case .windowClosed: return closed
        default: return nil
        }
    }
}

/// Merges the three sources into rows: paired SpanDACs first, then ones seen
/// but not paired, each group by name. `selected` keeps a row for the chosen
/// SpanDAC even when it is neither paired nor seen, so the selection never
/// disappears from the screen. `notPairableNow` holds the row words of a
/// refusal still standing for that `sourceID`.
func spandacOutputRows(paired: [SpanDACPairRecord], seen: [SpanDACSighting],
                       probes: [String: SpanDACOutputs.Probe],
                       outputs: [String: SourceOutputInfo] = [:],
                       notPairableNow: [String: String] = [:],
                       pairing: SpanDACOutputs.PairingState?,
                       forgetPrompt: String?, selected: String?) -> [SpanDACOutputRow] {
    let seenByID = Dictionary(seen.map { ($0.sourceID, $0) }, uniquingKeysWith: { first, _ in first })

    func state(for id: String, paired: Bool) -> (SpanDACRowState, String) {
        if forgetPrompt == id { return (.forgetPrompt, "forget? y / n") }
        if let pairing, pairing.sourceID == id {
            switch pairing.phase {
            case .connecting: return (.connecting, pairing.note)
            case .confirming(let deadline): return (.waitingForAllow(deadline: deadline), pairing.note)
            }
        }
        if let why = notPairableNow[id] { return (.notPairableNow(why), why) }
        guard paired else {
            return seenByID[id]?.txt.pairingPort != nil
                ? (.notPaired(pairable: true), "not paired · Enter to pair")
                : (.notPaired(pairable: false), "not paired · open SpanDAC on it to pair")
        }
        // An explicit unknown DAC is still checking, whatever else was said.
        if outputs[id]?.dac == .unknown { return (.checking, "checking the DAC") }
        switch probes[id] {
        case .ready?: return (.ready, "ready")
        case .unavailable(let why)?: return (.notReady(why), why)
        case .unreachable(let why)?: return (.unreachable(why), why)
        case .forgotten?: return (.forgotten, "forgot this Mac  Enter to pair again")
        case .needsRepair(let why)?: return (.needsRepair(why), why)
        case .checking?, nil: return (.checking, "checking…")
        }
    }

    func row(_ id: String, name: String, paired: Bool) -> SpanDACOutputRow {
        let (rowState, note) = state(for: id, paired: paired)
        return SpanDACOutputRow(sourceID: id, name: name, paired: paired, note: note, ready: rowState == .ready,
                                state: rowState, output: paired ? outputs[id] : nil)
    }

    var rows: [SpanDACOutputRow] = []
    for record in paired.sorted(by: { ($0.sourceName, $0.sourceID) < ($1.sourceName, $1.sourceID) }) {
        rows.append(row(record.sourceID, name: record.sourceName, paired: true))
    }
    let pairedIDs = Set(paired.map(\.sourceID))
    for sighting in seen.filter({ !pairedIDs.contains($0.sourceID) })
        .sorted(by: { ($0.txt.name, $0.sourceID) < ($1.txt.name, $1.sourceID) }) {
        rows.append(row(sighting.sourceID, name: sighting.txt.name, paired: false))
    }
    if let selected, !rows.contains(where: { $0.sourceID == selected }) {
        let name = seenByID[selected]?.txt.name ?? "SpanDAC"
        rows.append(SpanDACOutputRow(sourceID: selected, name: name, paired: false,
                                     note: "not paired · not found on this network", ready: false,
                                     state: .unreachable("not found on this network")))
    }
    return rows
}

/// The Output tab's SpanDACs on the network: discovery, readiness probes,
/// pairing and forgetting. Background work lands in state guarded by one
/// lock; the scene reads `rows` on its own loop and asks `tick()` whether
/// anything changed.
final class SpanDACOutputs {

    /// What the last authenticated status request said, per SpanDAC.
    enum Probe: Equatable {
        case checking
        case ready
        /// It answered and cannot play: the reason, in words.
        case unavailable(String)
        /// Not found, asleep, no answer: the reason, in words.
        case unreachable(String)
        /// TLS -9864: the SpanDAC no longer knows this Mac. The pair is kept.
        case forgotten
        /// TLS -9820 / -9846: the secret does not match. The pair is kept.
        case needsRepair(String)
    }

    struct PairingState: Equatable {
        enum Phase: Equatable {
            case connecting
            /// The key confirmation is running. MusicTUI's own side answered
            /// automatically; only the device's person still has something to
            /// do, by tapping Allow there before `deadline`.
            case confirming(deadline: Date)
        }
        let sourceID: String
        let name: String
        var phase: Phase

        var note: String {
            switch phase {
            case .connecting: return "pairing…"
            case .confirming: return "pairing · tap Allow on \(name)"
            }
        }
    }

    /// How often a paired SpanDAC is asked again while the tab is shown.
    /// CHOSEN (a composer default, not measured): quick enough that a row
    /// turns ready by itself soon after the DAC is plugged in or the app
    /// opened, slow enough to be one small request per device.
    static let reprobeInterval: TimeInterval = 5
    /// How long the browser keeps running after the last `touch()`.
    static let browseLease: TimeInterval = 2
    /// Row words for a secret mismatch (C-FORGOT).
    static let needsRepairReason = "pairing broken  Enter to pair again"

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
    private var outputs: [String: SourceOutputInfo] = [:]
    /// A standing "not now" refusal per `sourceID`, with the TXT record it
    /// was refused under: it stands until that record changes or Enter.
    private var refusals: [String: (reason: String, txt: SpanDACTXT?)] = [:]
    /// Probes in flight, one per SpanDAC at most.
    private var inFlight: Set<String> = []
    /// A fresh probe was asked for while one was in flight: that answer may be
    /// from before, so it is dropped and another probe follows.
    private var rerun: Set<String> = []
    private var lastProbeEnd: [String: Date] = [:]
    /// Just paired: the next fresh answer decides whether `onPairedAndReady`
    /// fires, once.
    private var awaitingReady: [String: String] = [:]
    /// Paired and ready, waiting for the scene's next `tick()` to announce.
    private var pairedAndReady: [(String, String)] = []
    private var pairing: PairingState?
    private var pairingHandle: SpanDACPairingHandle?
    private var forgetPrompt: String?
    private var version = 0
    private var seenVersion = 0
    private var lastTouch = Date.distantPast
    private var browsing = false
    /// `paired.json` as last read: on opening the tab, and after this
    /// process pairs or forgets. Not re-read on every frame.
    private var paired: [SpanDACPairRecord] = []

    /// Set once by the scene at composition. Fired at most once per
    /// successful pairing, and only when the new pair's first answer is
    /// ready; called from `tick()`, on the scene's own loop.
    var onPairedAndReady: ((_ sourceID: String, _ name: String) -> Void)?

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
        return spandacOutputRows(paired: paired, seen: sightings, probes: probes, outputs: outputs,
                                 notPairableNow: refusals.mapValues(\.reason), pairing: pairing,
                                 forgetPrompt: forgetPrompt, selected: selectedSourceID)
    }

    /// Re-reads `paired.json`.
    private func reloadPairs() {
        let fresh = pairs.pairs()
        lock.lock(); paired = fresh; version += 1; lock.unlock()
    }

    /// True once per change since the last call. Also announces a pairing
    /// that just became ready, on the caller's (the scene's) thread.
    func tick() -> Bool {
        lock.lock()
        let changed = version != seenVersion
        seenVersion = version
        let announce = pairedAndReady
        pairedAndReady = []
        let callback = onPairedAndReady
        lock.unlock()
        for (id, name) in announce { callback?(id, name) }
        return changed
    }

    /// Keeps the browser running for another lease and re-probes each paired
    /// SpanDAC whose last answer is `reprobeInterval` old. The scene calls
    /// this on every tick while the Output tab is shown, and only then.
    func touch() {
        lock.lock()
        let at = now()
        lastTouch = at
        let start = !browsing
        browsing = true
        let due = paired.map(\.sourceID).filter { id in
            !inFlight.contains(id) && pairing?.sourceID != id
                && at.timeIntervalSince(lastProbeEnd[id] ?? .distantPast) >= Self.reprobeInterval
        }
        lock.unlock()
        for id in due { probe(id, fresh: false) }
        guard start else { return }
        browser.start { [weak self] found in self?.sighted(found) }
        scheduleLeaseCheck()
    }

    /// A new Bonjour set: a standing refusal ends when that SpanDAC's TXT
    /// record changes (or it is no longer seen).
    private func sighted(_ found: [SpanDACSighting]) {
        lock.lock()
        sightings = found
        let txtByID = Dictionary(found.map { ($0.sourceID, $0.txt) }, uniquingKeysWith: { first, _ in first })
        for (id, refusal) in refusals where txtByID[id] != refusal.txt { refusals[id] = nil }
        version += 1
        lock.unlock()
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

    /// The tab was (re)opened: ask each paired SpanDAC how it is.
    func activated() {
        reloadPairs()
        if let problem = pairs.problem() { post(problem, true, 6) }
        lock.lock(); let ids = paired.map(\.sourceID); lock.unlock()
        for id in ids { probe(id) }
    }

    /// Whether a status request to this SpanDAC is in flight.
    func isProbing(_ sourceID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return inFlight.contains(sourceID)
    }

    /// One authenticated status read, off the input thread. At most one per
    /// SpanDAC is in flight: a fresh ask during one reruns after it, and a
    /// re-probe (`fresh: false`) keeps the row as it is until it answers.
    func probe(_ sourceID: String) { probe(sourceID, fresh: true) }

    private func probe(_ sourceID: String, fresh: Bool) {
        lock.lock()
        if fresh { probes[sourceID] = .checking; outputs[sourceID] = nil; version += 1 }
        if inFlight.contains(sourceID) {
            if fresh { rerun.insert(sourceID) }
            lock.unlock()
            return
        }
        inFlight.insert(sourceID)
        lock.unlock()
        let client = makeClient(sourceID)
        DispatchQueue.global().async { [weak self] in
            var output: SourceOutputInfo?
            let result: Probe
            do {
                let status = try client.control.status()
                output = status.output
                result = status.readiness == .ready ? .ready : .unavailable(status.readiness.label)
            } catch SourceAppError.link(let failure) {
                result = SpanDACOutputs.probe(for: failure)
            } catch {
                result = .unavailable(SourceReadiness.from(error).label)
            }
            self?.probeFinished(sourceID, result, output)
        }
    }

    /// A link failure as a row: an unknown identity is forgotten, a secret
    /// mismatch is broken; anything else (a remote close mid-request
    /// included, which stays "did not answer") is unreachable.
    static func probe(for failure: SpanDACLinkFailure) -> Probe {
        switch failure {
        case .refused(-9864): return .forgotten
        case .refused(-9820), .refused(-9846): return .needsRepair(needsRepairReason)
        default: return .unreachable(failure.note)
        }
    }

    private func probeFinished(_ sourceID: String, _ result: Probe, _ output: SourceOutputInfo?) {
        lock.lock()
        inFlight.remove(sourceID)
        lastProbeEnd[sourceID] = now()
        if rerun.remove(sourceID) != nil {
            lock.unlock()
            probe(sourceID, fresh: true)
            return
        }
        // A SpanDAC forgotten while this was in flight keeps no answer.
        guard paired.contains(where: { $0.sourceID == sourceID }) else {
            awaitingReady[sourceID] = nil
            lock.unlock()
            return
        }
        probes[sourceID] = result
        outputs[sourceID] = output
        if let name = awaitingReady.removeValue(forKey: sourceID), result == .ready {
            pairedAndReady.append((sourceID, name))
        }
        version += 1
        lock.unlock()
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

    /// Enter on a SpanDAC to pair (not paired, forgotten, broken, or refused
    /// earlier). Connects at once when its TXT record advertises a pairing
    /// port; otherwise does nothing. The port is an invitation only: the
    /// device decides, and a "not now" answer is shown on the row.
    func pair(_ sourceID: String) {
        lock.lock()
        guard pairing == nil else { lock.unlock(); return }
        let hadRefusal = refusals.removeValue(forKey: sourceID) != nil
        guard let sighting = sightings.first(where: { $0.sourceID == sourceID }),
              let port = sighting.txt.pairingPort else {
            if hadRefusal { version += 1 }
            lock.unlock()
            return
        }
        let name = sighting.txt.name
        pairing = PairingState(sourceID: sourceID, name: name, phase: .connecting)
        forgetPrompt = nil
        version += 1
        lock.unlock()

        let controllerID: String
        do {
            controllerID = try pairs.controllerID()
        } catch {
            finishPairing(.failure(.notSaved((error as? SpanDACPairedStoreError)?.message ?? "\(error)")),
                          txt: sighting.txt)
            return
        }
        let serviceName = sighting.serviceName
        let store = pairs
        let txt = sighting.txt
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
        }, events: { [weak self] event in self?.handle(event, txt: txt) })
        lock.lock()
        // Esc landed before the session existed: end it now.
        let cancelledMeanwhile = pairing?.sourceID != sourceID
        if !cancelledMeanwhile { pairingHandle = handle }
        lock.unlock()
        if cancelledMeanwhile { handle.cancel() }
    }

    private func handle(_ event: SpanDACPairingEvent, txt: SpanDACTXT) {
        switch event {
        case .code:
            // The key confirmation the wire protocol runs is unchanged; only
            // who answers "matches" does. MusicTUI answers its own side at
            // once, with no prompt — only the device's person still taps
            // anything, via its own Allow / Don't allow.
            lock.lock(); let handle = pairingHandle; lock.unlock()
            handle?.answer(matches: true)
        case .confirming:
            lock.lock()
            let name = pairing?.name ?? "SpanDAC"
            // The device's Allow prompt closes by itself after the same
            // confirm bound this side waits.
            pairing?.phase = .confirming(deadline: now().addingTimeInterval(SpanDACPairingController.confirmTimeout))
            version += 1
            lock.unlock()
            post("Tap Allow on \(name).", false, SpanDACPairingController.confirmTimeout)
        case .finished(let result):
            finishPairing(result, txt: txt)
        }
    }

    /// `txt` is the record the pairing was started under; a "not now"
    /// refusal stands until that record changes.
    private func finishPairing(_ result: Result<SpanDACPairResult, SpanDACPairFailure>, txt: SpanDACTXT?) {
        lock.lock()
        let sourceID = pairing?.sourceID ?? txt?.sourceID
        pairing = nil
        pairingHandle = nil
        if case .failure(let failure) = result, let sourceID, let reason = SpanDACNotPairableNow.reason(for: failure) {
            refusals[sourceID] = (reason, txt)
        }
        version += 1
        lock.unlock()
        switch result {
        case .success(let pair):
            reloadPairs()
            lock.lock(); awaitingReady[pair.sourceID] = pair.sourceName; lock.unlock()
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

    /// Esc: drop a pending question or a pairing in progress. A pairing ends
    /// when its session reports the cancel; nothing is saved and nothing is
    /// announced.
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
        lock.unlock()
        if let handle { handle.cancel() } else { finishPairing(.failure(.cancelled), txt: nil) }
        return true
    }

    // MARK: - Forgetting

    /// `f` on a paired SpanDAC: ask first.
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
    /// this process has open to it. The device's own list is the device's:
    /// this does not remove the Mac there. The only way, with a successful
    /// re-pair, that a local pair is ever deleted.
    func forget(_ sourceID: String) {
        let name = pairs.pair(for: sourceID)?.sourceName ?? "SpanDAC"
        do {
            try pairs.forget(sourceID: sourceID)
        } catch {
            post((error as? SpanDACPairedStoreError)?.message ?? "\(error)", true, 6)
            return
        }
        registry.cancelAll(sourceID)
        lock.lock()
        probes[sourceID] = nil
        outputs[sourceID] = nil
        awaitingReady[sourceID] = nil
        version += 1
        lock.unlock()
        reloadPairs()
        post("Forgot \(name). Remove this Mac in SpanDAC on \(name) too.", false, 5)
    }
}
