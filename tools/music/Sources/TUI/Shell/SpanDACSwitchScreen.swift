// tools/music/Sources/TUI/Shell/SpanDACSwitchScreen.swift
//
// The Output tab's side of where MusicTUI's music DATA comes from: the
// one-time "Switch MusicTUI to SpanDAC?" screen, what the tab says before
// SpanDAC on this Mac is set up, and the way back ("Stop using SpanDAC for
// music data"). The words are the agreed canvas copy; the pieces here are pure
// so the scene draws them and a test reads them without a terminal.
//
// Where sound goes is a different question, answered by the rows below the
// switch: nothing here changes the output.
import Foundation

// MARK: - The words

/// The switch screen, as agreed on the canvas (Anthony's own edits, with the
/// `=` line as amended on 2026-09-28). The keys are the tab's footer.
///
/// The canvas's grey bottom line ("From now on MusicTUI gets its music data
/// from SpanDAC. SpanDAC runs quietly in the background on this Mac; MusicTUI
/// starts it when it isn't running.") is a note on behaviour, implemented by
/// the routing and the starter, and deliberately not drawn.
enum SpanDACSwitchCopy {
    static let eyebrow = "SPANDAC IS SET UP ON THIS MAC"
    static let question = "Switch MusicTUI to SpanDAC?"
    static let points = [
        "+ Search, Discover and Radio come straight from Apple Music. No developer key.",
        "+ Lossless to your DAC, on this Mac, your iPhone or iPad, when you pick one in Output.",
        "= Your library and new music still play on MusicTUI and your speakers.",
    ]
    static let keys = "Enter Switch to SpanDAC   Esc Not now"
}

/// The SPANDAC section when SpanDAC is not on this Mac (canvas copy).
enum NoMacSpanDACCopy {
    static let title = "SPANDAC"
    static let note = "not set up on this Mac"
    static let pitch = "Lossless to your DAC, and Apple Music without a developer key."
    static let install = "Install SpanDAC on this Mac to start. Your iPhone and iPad work with it once it's set up."
    /// Prefix for a SpanDAC on the network while there is none on this Mac.
    static let seen = "seen on your network"
}

/// The way back to MusicTUI's own music data (Anthony, 2026-09-28 12:19).
let stopUsingSpanDACText = "Stop using SpanDAC for music data"
/// Asked before anything happens. CHOSEN wording (score default); drawn as
/// the sentence, then its keys, which never break apart.
let stopUsingSpanDACAsk = "Stop using SpanDAC for music data? MusicTUI goes back to its own library and search."
let stopUsingSpanDACKeys = "y Yes  n No"
let stopUsingSpanDACQuestion = stopUsingSpanDACAsk + "  " + stopUsingSpanDACKeys
/// Toasts after the person's answer. CHOSEN wording.
let switchedToSpanDACData = "MusicTUI now gets its music data from SpanDAC."
let backToMusicTUIData = "MusicTUI is using its own music data again."
/// The top line while a stored SpanDAC output waits on the switch. CHOSEN.
let waitingOnTheSwitchToSpanDAC = "not ready  switch not finished"

// MARK: - SpanDAC on this Mac, for music data

/// Sentences `slice.status` (and a refused request) use for a SpanDAC that
/// answered but may not use Apple Music. **Copies, named rather than hidden:**
/// they come from the client's `readiness(from:)` and `SourceReadiness.from`,
/// so a wording change there turns "needs Apple Music access" into the plain
/// reason on the Mac row (still shown, never a guess).
private let macSpanDACAccessSentences: Set<String> = [
    "SpanDAC has not been granted Apple Music access yet",
    "SpanDAC was denied Apple Music access",
    "Apple Music access is restricted on this Mac",
    "SpanDAC could not read its Apple Music access",
    "SpanDAC has no Apple Music access",
]

/// Reasons that are only about the DAC. Music DATA does not need a DAC, so a
/// SpanDAC that answers, authorized, with no DAC plugged in can still serve it.
private let macSpanDACDACOnlySentences: Set<String> = [
    "plug in your DAC",
    "SpanDAC is still checking for a DAC",
]

/// Whether SpanDAC on this Mac can serve music DATA, from its status: ready
/// when it answered and may use Apple Music, whatever its DAC says (an
/// output-only concern). Every other state is passed through unchanged.
func macDataReadiness(_ readiness: SourceReadiness) -> SourceReadiness {
    if case .unavailable(let why) = readiness, macSpanDACDACOnlySentences.contains(why) { return .ready }
    return readiness
}

/// Whether a status says SpanDAC on this Mac needs Apple Music access.
func macSpanDACNeedsAccess(_ readiness: SourceReadiness) -> Bool {
    if case .unavailable(let why) = readiness { return macSpanDACAccessSentences.contains(why) }
    return false
}

/// SpanDAC on this Mac before MusicTUI has switched to it: the Mac row's
/// state as the switch sees it (C-CEREMONY's "installed, not switched").
enum MacDataRowState: Equatable {
    case checking
    /// Neither LaunchServices nor a socket knows it. The tab shows the
    /// "not set up on this Mac" box instead of a row.
    case notInstalled
    /// Answered, may use Apple Music: Enter shows the switch screen.
    case ready
    /// Installed, not answering: Enter starts it.
    case notRunning
    /// Answered, not allowed Apple Music: Enter brings it forward.
    case needsAccess
    /// A start this tab asked for is under way.
    case starting
    /// A start this tab asked for ended without SpanDAC ready; the sentence
    /// says why, and Enter tries again.
    case startFailed(String)
    /// Anything else, in its own words.
    case other(String)
}

/// Decides the Mac row before the switch. `installed` is nil until asked;
/// `startOutcome` is the last start this tab asked for (nil once a later
/// status reads ready, or before any).
func macDataRowState(readiness: SourceReadiness, installed: Bool?, starting: Bool,
                     startOutcome: MacSpanDACStartOutcome?) -> MacDataRowState {
    if starting { return .starting }
    let data = macDataReadiness(readiness)
    if data == .ready { return .ready }
    switch startOutcome {
    case .notInstalled?: return .notInstalled
    case .notAuthorized?: return .needsAccess
    case .timedOut?, .failed?: return .startFailed(startOutcome?.sentence ?? "")
    case .ready?, nil: break
    }
    if macSpanDACNeedsAccess(data) { return .needsAccess }
    if installed == false, data == .notRunning || data == .checking { return .notInstalled }
    switch data {
    case .checking: return .checking
    case .ready: return .ready
    case .unavailable(let why):
        return data == .notRunning ? .notRunning : .other(why)
    }
}

/// Every word the Mac row shows before the switch.
func macDataRowDetail(_ state: MacDataRowState) -> SpanDACRowDetail {
    switch state {
    case .checking: return SpanDACRowDetail(text: "checking\u{2026}", tone: .neutral)
    case .notInstalled: return SpanDACRowDetail(text: MacSpanDACStartOutcome.notInstalled.sentence, tone: .warning)
    case .ready: return SpanDACRowDetail(text: "ready  Enter to switch MusicTUI to SpanDAC", tone: .ready)
    case .notRunning: return SpanDACRowDetail(text: "not running  Enter to start it", tone: .warning)
    case .needsAccess: return SpanDACRowDetail(text: "needs Apple Music access  Enter to open SpanDAC", tone: .warning)
    case .starting: return SpanDACRowDetail(text: startingSpanDAC, tone: .active)
    case .startFailed(let why): return SpanDACRowDetail(text: why, tone: .warning)
    case .other(let why): return SpanDACRowDetail(text: why, tone: .warning)
    }
}

/// A SpanDAC on the network before the switch (C-SEED-ROW): drawn, never
/// chosen. `macMissing` adds that it was seen, for the "not set up" box.
func needsMacSpanDACDetail(macMissing: Bool) -> SpanDACRowDetail {
    let needs = spandacRowDetail(state: .needsMacSpanDAC, output: nil, device: "", isThisMac: false,
                                 now: Date()).text
    return SpanDACRowDetail(text: macMissing ? "\(NoMacSpanDACCopy.seen) \u{00B7} \(needs)" : needs,
                            tone: .neutral)
}

// MARK: - Wrapping

/// `text` in lines of at most `width` columns, broken at spaces. A line that
/// starts with "+ " or "= " continues under its own words, not under the
/// sign. A single word longer than `width` is cut, never dropped.
func wrapForOutputTab(_ text: String, width: Int) -> [String] {
    guard width > 0 else { return [] }
    let hanging = text.hasPrefix("+ ") || text.hasPrefix("= ") ? "  " : ""
    var lines: [String] = []
    var line: String? = nil
    // Empty pieces keep a double space ("search.  y Yes") where it fits.
    for word in text.split(separator: " ", omittingEmptySubsequences: false).map(String.init) {
        guard let current = line else { line = word; continue }
        let candidate = current + " " + word
        if candidate.count <= width {
            line = candidate
        } else if word.isEmpty {
            continue   // a double space at a break is just the break
        } else {
            lines.append(current)
            line = hanging + word
        }
        // A word wider than the line is cut into pieces, never dropped.
        while let long = line, long.count > width, width > hanging.count {
            lines.append(String(long.prefix(width)))
            line = hanging + String(long.dropFirst(width))
        }
    }
    if let line, !line.isEmpty { lines.append(line) }
    return lines
}
