// tools/music/Sources/TUI/Shell/BridgeNow.swift
import Foundation

/// What the Now tab knows about Bridge, derived only from `slice.status`.
///
/// **Three counters, three quantities, never one label.** `.building(ready:)`
/// counts songs READY while the queue is built; `index` is the playback
/// position, 0-based within the present entries, shown as `index + 1`; and an
/// invalid queue carries `built` (songs ready before the failure) because the
/// app sends `present` as nil then — not zero. Rendering one as another is how
/// a screen ends up saying "song 0 of 12" over a queue that failed at 7.
///
/// Pure data. Nothing here reads a socket; `PlaybackPoller` feeds it and
/// `NowPlayingScene` draws it.
struct BridgeNow: Equatable {
    enum Link: Equatable { case checking, answering, notResponding, unavailable(String) }
    enum Queue: Equatable {
        case none
        case building(ready: Int?, requested: Int)
        /// `present` is set only when SpanDAC queued fewer songs than were
        /// requested; nil when every requested song is present or it did not say.
        case complete(requested: Int, present: Int? = nil)
        case invalid(reason: String, built: Int?, requested: Int)
    }
    var link: Link
    var playback: String      // raw wire value: playing/paused/loading/idle/stopped
    var title: String
    var artist: String
    var queue: Queue
    var index: Int?           // 0-based, within present entries
    /// The playing song's cover, when SpanDAC sends one. Nil draws the same
    /// gradient placeholder as a Music.app track with no artwork.
    var artworkURL: String? = nil
    /// The playing song's Music.app persistent ID as SpanDAC sends it (a signed
    /// decimal alias, verbatim), when it sends one: the way to a cover when `artworkURL` is absent or not fetchable.
    /// When the status has none, the poller fills it with the alias of the
    /// sent row the status's `row` names (`spanDACQueueWindow`), so the cover
    /// takes the same rung either way.
    var persistentID: String? = nil
    /// SpanDAC's shuffle and repeat state, and which of the two it offers
    /// control of (its `capabilities` named the op). Defaults read as an older
    /// build: no state, nothing offered.
    var shuffle: Bool? = nil
    var repeatMode: String? = nil
    var offersShuffle = false
    var offersRepeat = false

    /// Before Bridge has answered even once.
    static let empty = BridgeNow(link: .checking, playback: "idle", title: "", artist: "",
                                 queue: .none, index: nil)
}

/// One successful `slice.status` reply as the Now tab's view of Bridge.
///
/// **An unready reply is not an outage.** Bridge answered, so a contract
/// mismatch or missing authorisation shows its own reason at once, with no
/// grace period: waiting would only delay a diagnosis that is already certain.
func bridgeNow(from status: SourceStatus) -> BridgeNow {
    let link: BridgeNow.Link
    switch status.readiness {
    case .ready:                   link = .answering
    case .unavailable(let reason): link = .unavailable(reason)
    case .checking:                link = .unavailable(status.readiness.label)
    }
    let requested = status.queueRequested ?? 0
    let queue: BridgeNow.Queue
    switch status.queuePhase {
    case "building": queue = .building(ready: status.queuePresent, requested: requested)
    case "complete":
        let short = status.queuePresent.flatMap { $0 >= 0 && $0 < requested ? $0 : nil }
        queue = .complete(requested: requested, present: short)
    case "invalid":
        queue = .invalid(reason: status.queueReason ?? "the queue could not be built",
                         built: status.queueBuiltBeforeFailure, requested: requested)
    default:         queue = .none
    }
    return BridgeNow(link: link, playback: status.playback,
                     title: status.title ?? "", artist: status.artist ?? "",
                     queue: queue, index: status.queueIndex, artworkURL: status.artworkURL,
                     persistentID: status.persistentID,
                     shuffle: status.shuffle, repeatMode: status.repeatMode,
                     offersShuffle: status.offersShuffle, offersRepeat: status.offersRepeat)
}

/// What the Now tab says in place of the control grid when SpanDAC does not
/// list `slice.shuffle` or `slice.repeat` (an older build).
let spanDACNoModesSentence = "Shuffle and repeat aren't available on SpanDAC."

/// Keeps a failed read from flashing a diagnosis.
///
/// **One miss is a hiccup, two are a finding.** The first failed `status()`
/// after a good reply returns that reply unchanged; the second consecutive one
/// says Bridge is not responding. Any success resets the count. This matches
/// the Music.app path, which keeps its last snapshot on `.unavailable`.
struct BridgeLinkTracker {
    private(set) var misses = 0
    private var last: BridgeNow? = nil

    /// True while a failure is being absorbed: the caller should keep showing
    /// what it showed before, not a stop.
    var inGrace: Bool { misses == 1 }

    mutating func record(_ result: Result<SourceStatus, Error>) -> BridgeNow {
        switch result {
        case .success(let status):
            let now = bridgeNow(from: status)
            misses = 0
            last = now
            return now
        case .failure:
            misses += 1
            if misses < 2 { return last ?? .empty }
            var gone = last ?? .empty
            gone.link = .notResponding
            gone.playback = "stopped"
            gone.queue = .none
            gone.index = nil
            return gone
        }
    }
}

/// The one line of queue or link state, plain text with no ANSI, or nil when
/// there is nothing to say. Precedence is the order of the checks: the link
/// first (nothing else is trustworthy without it), then a failed queue, then
/// the settle window after a command, then a queue still being built.
func bridgeStatusLine(_ b: BridgeNow) -> String? {
    switch b.link {
    case .checking:      return "Checking SpanDAC\u{2026}"
    case .notResponding: return "SpanDAC is not responding."
    case .unavailable(let reason): return reason.hasSuffix(".") ? reason : reason + "."
    case .answering:     break
    }
    if case .invalid(let reason, let built, let requested) = b.queue {
        // A reason carrying a system error's own text can already end in a stop.
        let said = reason.hasSuffix(".") ? String(reason.dropLast()) : reason
        guard let built else { return "Stopped: \(said)." }
        return "Stopped: \(said). \(built) of \(requested) built."
    }
    if b.playback == "loading" { return "Loading\u{2026}" }
    if case .building(let ready, let requested) = b.queue {
        guard let ready else { return "Building queue of \(requested)\u{2026}" }
        return "Building queue: \(ready) of \(requested) ready."
    }
    // SpanDAC queued fewer songs than asked for: a finished queue, said as it is.
    if case .complete(let requested, let present?) = b.queue {
        return "\(present) of \(requested) queued."
    }
    return nil
}

/// "Song N of M", only when Bridge reported a position inside a live queue.
/// **Never inferred from `present`**: songs ready is not the song playing.
func bridgePositionLine(_ b: BridgeNow) -> String? {
    guard let index = b.index else { return nil }
    let requested: Int
    switch b.queue {
    case .building(_, let m): requested = m
    // The index counts the songs that are present, so a short queue's total is
    // the songs there, not the number asked for.
    case .complete(let m, let present): requested = present ?? m
    case .none, .invalid: return nil
    }
    guard requested > 0, index >= 0, index < requested else { return nil }
    return "Song \(index + 1) of \(requested)"
}

/// SpanDAC's queue as the Now tab's EXISTING Up Next draws it: the same
/// `TrackListEntry` rows the Music.app path fills `surrounding` with, the
/// playing row first (`isCurrent`), then every row after it (the renderer
/// scrolls, as it does for the Music.app path, which passes its whole queue). `index` is the
/// row's 1-based place in the list the client sent.
///
/// `sent` is what the current play sent (`RoutingCoordinator.spanDACPlayedRows`);
/// `row` and `next_rows` index it. Without `next_rows`, the rows after `row` in
/// sent order stand in. `current` is the sent row at `row`: its alias is the
/// cover's way in when the status carries no persistent ID.
///
/// **Nothing is shown that the status does not vouch for.** No sent list, no
/// `row`, a `row` outside the list, or a row whose title is not the title the
/// status reports playing (a play from another process, say) all give nothing,
/// which leaves the Now tab exactly as it was before this existed.
///
/// `token` is the `queue_token` the play's reply carried (Codex 106, finding 6).
/// When there is one, the rows are used only while the status echoes the same
/// token, so another process's queue can never borrow them: no Up Next, no
/// album line, no persistent-id fallback for the cover. Without one (a SpanDAC
/// that predates tokens) the title check above is the whole rule, as before.
///
/// `shuffled` is true when the play was a shuffle SpanDAC made itself.
func spanDACQueueWindow(sent: [MusicRow]?, token: String? = nil, shuffled: Bool = false,
                        status: SourceStatus) -> (current: MusicRow?, entries: [TrackListEntry]) {
    guard let sent, let at = status.row, sent.indices.contains(at) else { return (nil, []) }
    // The play recorded a token: these rows describe that assignment and no
    // other. A status that echoes a different token (another process replaced
    // the queue) or none (the player was unloaded) shows its own data only.
    if let token, status.queueToken != token { return (nil, []) }
    let current = sent[at]
    if let title = status.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty,
       title.lowercased() != current.title.trimmingCharacters(in: .whitespaces).lowercased() {
        return (nil, [])
    }
    // `next_rows` absent: in sent order the rows after `row` stand in, as ever.
    // But a play SpanDAC shuffled itself, or a status that says shuffle is on,
    // has no order the sent rows could stand in for, and SpanDAC may leave
    // `next_rows` out then: no Up Next list, never an error and never a guess.
    let unorderedWithoutNextRows = shuffled || status.shuffle == true
    let next = status.nextRows.map { $0.filter { sent.indices.contains($0) } }
        ?? (unorderedWithoutNextRows ? [] : Array((at + 1)..<sent.count))
    func entry(_ i: Int, current: Bool) -> TrackListEntry {
        TrackListEntry(index: i + 1, name: sent[i].title, artist: sent[i].artist, isCurrent: current, album: sent[i].album)
    }
    return (current, [entry(at, current: true)] + next.map { entry($0, current: false) })
}
