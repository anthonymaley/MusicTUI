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

/// Whether the source app can actually serve, which is four states rather than
/// two (Codex M2). `connected` is not `ready`: two independently released
/// binaries can be connected and authorised while one lacks an operation the
/// other needs. This is a product-level status, not capability negotiation.
enum SourceReadiness: Equatable {
    /// No socket, or nothing listening on it.
    case disconnected
    /// Reachable, but the app has no Apple Music access.
    case unauthorized
    /// Reachable and authorised, but missing an operation this build requires.
    case incompatible
    /// Reachable, authorised, and able to serve.
    case ready

    var label: String {
        switch self {
        case .disconnected: return "not running"
        case .unauthorized: return "no Apple Music access"
        case .incompatible: return "version mismatch"
        case .ready:        return "ready"
        }
    }

    /// Only a ready source may be selected. Codex I5: requiring readiness
    /// BEFORE the switch begins is what stops a failed selection interrupting
    /// playback that was working.
    var canSelect: Bool { self == .ready }
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
