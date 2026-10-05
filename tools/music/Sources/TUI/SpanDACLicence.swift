import Foundation

// SpanDAC's licence, as MusicTUI sees it: status handling only.
//
// SpanDAC reports whether it is willing to serve in an optional `licence`
// object on `slice.status`, and refuses every other op with the error kind
// `unlicensed` while it is not. MusicTUI reads one bit from that (serving or
// not), shows SpanDAC's own sentence, and never sees, stores or sends a key.
//
// Absent means serving: an older SpanDAC, or one built without licensing, sends
// no object and is read exactly as before.

/// The refusal kind a not-serving SpanDAC answers every gated op with.
let spanDACLicenceRefusalKind = "unlicensed"

/// What SpanDAC's `licence` object says. `state` is its own spelling
/// (`licensed`, `licensed_offline`, `none`, `check_in`, `invalid`,
/// `unreadable`, `store_error`) and is carried, never decided on; `serving` is
/// the one bit a client acts on; `text` is shown verbatim.
struct SpanDACLicenceInfo: Equatable {
    let serving: Bool
    let state: String
    let text: String

    /// What a person reads when a reply says it is not serving and gives no
    /// sentence of its own, or sends a `licence` this build cannot read.
    static let unreadableText = "SpanDAC's licence could not be read"

    /// Nil when the reply has no `licence` (absent or null). A present object
    /// that is not readable **fails closed**: not serving, state `unreadable`.
    init?(status: [String: Any]) {
        guard let raw = status["licence"], !(raw is NSNull) else { return nil }
        guard let object = raw as? [String: Any], let serving = Self.strictBool(object["serving"]) else {
            self.init(serving: false, state: "unreadable", text: Self.unreadableText)
            return
        }
        let text = (object["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.init(serving: serving,
                  state: object["state"] as? String ?? "unreadable",
                  text: text.isEmpty && !serving ? Self.unreadableText : text)
    }

    /// A JSON `true` or `false` only. Foundation reads the number 1 as a Bool
    /// through `as? Bool`, and a licence bit that fails closed must not.
    private static func strictBool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    init(serving: Bool, state: String, text: String) {
        self.serving = serving
        self.state = state
        self.text = text
    }
}

/// Whether a `slice.status` body (the object under `status`) says SpanDAC is
/// serving. Absent or null `licence` is true; a Bool `serving` is itself; a
/// `licence` that is present and malformed is false.
func spanDACServing(_ status: [String: Any]) -> Bool {
    SpanDACLicenceInfo(status: status)?.serving ?? true
}

/// The one plain line a person reads while SpanDAC is installed and not
/// serving: what happened, what MusicTUI does instead, then SpanDAC's own
/// sentence. The output name is the one every other surface uses.
func spanDACNotLicensedLine(_ text: String) -> String {
    let detail = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let head = "SpanDAC is installed but not licensed - using the \(musicTUIOutputName) output instead."
    return detail.isEmpty ? head : head + " " + detail
}

/// Shown where an iPhone or iPad SpanDAC would be chosen while the Mac's
/// SpanDAC is not serving, or has not said that it is.
let iPhoneIPadNeedsLicensedMac = "iPhone/iPad SpanDAC needs SpanDAC for Mac, licensed."

/// The last thing the Mac's SpanDAC said about serving, learned from the
/// replies that already go by, so nothing here sends a request of its own.
///
/// Every reply is observed on the way through (`observingLicence`), from any
/// thread, hence the lock.
///
/// **Freshness (Codex review 100, finding 2).** Requests overlap (the launch
/// prime, the reprobe, the Output tab, the poller, actions), and their replies
/// can complete in any order. The lock prevents torn memory, not a stale
/// completion, so each request takes a monotonic `ticket()` BEFORE it is sent,
/// and its reply is applied only if that ticket is newer than the one that
/// last set the same value. Serving and the loaded queue are tracked
/// separately, because an `unlicensed` refusal says nothing about the queue.
final class SpanDACServingCache {
    private let lock = NSLock()
    private var serving: Bool? = nil
    private var changes = 0
    private var bridgeLoaded = false
    private var issued: UInt64 = 0
    private var servingTicket: UInt64 = 0
    private var loadedTicket: UInt64 = 0

    init() {}

    /// A ticket for a request about to be sent: greater than every ticket
    /// handed out before it.
    func ticket() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        issued += 1
        return issued
    }

    /// A reply observed with no request ticket of its own is taken as the
    /// newest: it is given a ticket now.
    func observe(replyLine: String) {
        observe(replyLine: replyLine, ticket: ticket())
    }

    /// A `slice.status` reply sets serving from its `licence` (absent = true)
    /// and whether a Bridge queue is loaded. An `unlicensed` error from any op
    /// sets serving false until the next status. Anything else, including a
    /// line that does not parse or a status without `playback`, changes
    /// nothing. A reply whose `ticket` is not newer than the one that last set
    /// a value leaves that value as it is.
    func observe(replyLine: String, ticket: UInt64) {
        guard let data = replyLine.data(using: .utf8),
              let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = reply["ok"] as? Bool else { return }
        if ok {
            guard let status = reply["status"] as? [String: Any],
                  let playback = status["playback"] as? String else { return }
            let phase = (status["queue"] as? [String: Any])?["phase"] as? String
            let loaded = (phase == "building" || phase == "complete")
                && playback != "stopped" && playback != "idle"
            record(serving: spanDACServing(status), bridgeLoaded: loaded, ticket: ticket)
        } else {
            let error = reply["error"] as? [String: Any]
            if error?["kind"] as? String == spanDACLicenceRefusalKind {
                record(serving: false, bridgeLoaded: nil, ticket: ticket)
            }
        }
    }

    /// `serving` is nil until something has been observed. `changes` counts
    /// every change of that value, from nil included, so two reads of it that
    /// differ say it moved and a repeat of the same answer does not. `bridgeLoaded`
    /// is true while the last status showed a queue built or building that has
    /// not stopped; an `unlicensed` error leaves it as it was.
    func snapshot() -> (serving: Bool?, changes: Int, bridgeLoaded: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (serving, changes, bridgeLoaded)
    }

    private func record(serving new: Bool, bridgeLoaded loaded: Bool?, ticket: UInt64) {
        lock.lock(); defer { lock.unlock() }
        if ticket > servingTicket {
            if serving != new { changes += 1 }
            serving = new
            servingTicket = ticket
        }
        if let loaded, ticket > loadedTicket {
            bridgeLoaded = loaded
            loadedTicket = ticket
        }
    }
}

/// A transport that reports every reply it returns to `cache` and otherwise
/// changes nothing: the same bytes come back, and an error from the transport
/// is thrown as it was, unobserved. The request's ticket is taken BEFORE it
/// is sent, so a reply that completes after a newer request's never
/// overwrites that newer evidence.
func observingLicence(_ transport: @escaping (String, String) throws -> String,
                      cache: SpanDACServingCache) -> (String, String) throws -> String {
    { path, line in
        let ticket = cache.ticket()
        let reply = try transport(path, line)
        cache.observe(replyLine: reply, ticket: ticket)
        return reply
    }
}
