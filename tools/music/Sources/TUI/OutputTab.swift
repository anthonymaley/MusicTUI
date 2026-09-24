// The Output tab's row model and selection rules, kept pure so the tab is
// testable without a terminal.
//
// Source Mode v1 section 4 (Anthony's GO, 2026-09-13). The Speakers tab becomes
// Output: the playback mode is chosen here, catalogue access shows its state
// beneath it, and AirPlay outputs follow.
//
// EQ and Visualizer are deliberately absent. They are Music.app-specific,
// contribute nothing to source playback, and Anthony judged them not useful for
// TUI use. The `music eq` and `music visualizer` CLI verbs remain.
import Foundation

/// Whether Bridge can serve, and if not, why.
///
/// **Two states, not four** (ruling 12.13, 2026-09-15; DoD 12). Revision 5 had
/// `disconnected`, `unauthorized`, `incompatible` and `ready`, and nothing could
/// produce the middle two: the wire carried no authorization and no contract
/// version, so a client could only ever tell "answered" from "did not answer".
/// Those fields exist now, and what the Output tab actually needs is one line a
/// person can act on.
enum SourceReadiness: Equatable {
    /// Nothing has asked Bridge yet.
    ///
    /// **Its own state, not a pessimistic guess.** The first version of this tab
    /// initialised to "not running" and never refreshed, so it reported Bridge
    /// down while Bridge was up and answering (2026-09-16 gate). A value meaning
    /// "unknown" that reads as a diagnosis is how that became invisible: the
    /// screen looked like a finding instead of an unfilled field.
    case checking
    case ready
    /// Why not, in words for the Output tab. Never empty.
    case unavailable(String)

    var label: String {
        switch self {
        case .checking: return "checking…"
        case .ready: return "ready"
        case .unavailable(let reason): return reason
        }
    }

    /// Only a ready Bridge may be selected. Codex I5: requiring readiness BEFORE
    /// the switch begins is what stops a failed selection interrupting playback
    /// that was working.
    var canSelect: Bool { self == .ready }

    /// The app is not answering at all. Distinguished from every other reason
    /// because it is the one a person fixes by opening the app.
    static let notRunning = SourceReadiness.unavailable("Bridge is not running")

    /// Every way asking Bridge can fail, kept apart.
    ///
    /// They all render as one `unavailable` line, but they are DIFFERENT lines:
    /// collapsing them is what hid the wiring defect, because a client bug and a
    /// missing app produced identical words. The UI shape is one row; the
    /// diagnosis is not.
    static func from(_ error: Error) -> SourceReadiness {
        guard let error = error as? SourceAppError else {
            return .unavailable("Bridge could not be reached: \(error.localizedDescription)")
        }
        switch error {
        case .notRunning:        return .notRunning
        // Running, reachable, and not ready for THIS op yet. The Output tab
        // asks about status, which no snapshot gates, so this should not reach
        // here; if it ever does, it says what it is rather than "not running".
        case .warming(let why, _): return .unavailable("Bridge is preparing: \(why)")
        // Only a paged read can see this, and the Output tab does not make one;
        // it says what it is rather than being folded into a generic refusal.
        case .staleGeneration(let why): return .unavailable("Bridge's library changed mid-read: \(why)")
        case .malformedReply(let what): return .unavailable(what)
        case .notAuthorized:     return .unavailable("Bridge has no Apple Music access")
        case .refused(let why):  return .unavailable("Bridge refused: \(why)")
        case .timedOut:          return .unavailable("Bridge did not answer in time")
        case .socketUnavailable(let why): return .unavailable("Bridge's control socket is unusable: \(why)")
        case .unreadable:        return .unavailable("Bridge sent a reply this build could not read")
        case .didNotStart(let s): return .unavailable("Bridge did not start playback (\(s))")
        // Only a library read can see this, and the Output tab does not make
        // one (D6); if it ever does, this is the older-Bridge line rather than
        // a generic refusal.
        case .unsupported:       return .unavailable("Bridge is older than this MusicTUI — update Bridge")
        }
    }
}

/// What the Output tab displays, in order.
enum OutputDisplayRow: Equatable {
    case modeHeader
    case mode(PlaybackMode)
    case catalogHeader
    case catalogStatus
    case airplayHeader
    case speaker(Int)
}

/// Mode first because it is the only control that changes routing; catalogue
/// access is status beneath it; AirPlay last.
///
/// **AirPlay rows are listed in BOTH modes.** In Source Mode they do not act
/// (see `airPlayActs`), but hiding a person's speakers would answer a question
/// they did not ask. Showing them inert with a reason is the honest form, and
/// matches the rule that unsupported is stated rather than inferred.
func outputDisplayRows(speakerCount: Int,
                       mode: PlaybackMode,
                       sourceReady: SourceReadiness) -> [OutputDisplayRow] {
    var rows: [OutputDisplayRow] = [.modeHeader, .mode(.musicApp), .mode(.source)]
    rows.append(.catalogHeader)
    rows.append(.catalogStatus)
    rows.append(.airplayHeader)
    rows += (0..<speakerCount).map { .speaker($0) }
    return rows
}

/// AirPlay routing stays MusicTUI's, on the Music.app path.
///
/// Anthony, 2026-09-13: "airplay stays in TUI. the point of the bridge is DAC
/// not airplay." The source app exists to own playback beside a wired DAC, and
/// sending audio over the network is the thing it is there to avoid, so routing
/// never moves to it.
func airPlayActs(in mode: PlaybackMode) -> Bool {
    mode == .musicApp
}

/// Music.app is always selectable: it needs nothing to be reachable, and it is
/// the shipping default. The source is selectable only when ready.
func outputModeSelectable(_ mode: PlaybackMode, readiness: SourceReadiness) -> Bool {
    switch mode {
    case .musicApp: return true
    case .source:   return readiness.canSelect
    }
}
