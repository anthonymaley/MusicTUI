// tools/music/Sources/TUI/Shell/SpanDACTransport.swift
import Foundation

/// The transport the Now tab draws as a visible control row when the output is
/// SpanDAC. **Nothing here is new to the wire:** each cell is a key the footer
/// already names, and pressing the cell runs the same routed action that key
/// runs. `<` `>` and Space are the shell's globals (`resolveGlobalKey`), `[`
/// and `]` are the Now tab's own seek; `performSourceTransport` and the scene's
/// `seek(by:)` are the single place each of them lands, whichever way it was
/// asked for.
enum SpanDACTransport: CaseIterable, Equatable {
    case previous, playPause, next, seekBack, seekForward

    /// Seek is 30 s each way, exactly as `[` and `]`.
    static let seekStep: Double = 30

    /// The key that already does this, as the footer spells it.
    var keyLabel: String {
        switch self {
        case .previous:    return "<"
        case .playPause:   return "Space"
        case .next:        return ">"
        case .seekBack:    return "["
        case .seekForward: return "]"
        }
    }

    /// The keypress the shell or the Now tab resolves to this action.
    var key: KeyPress {
        switch self {
        case .previous:    return .char("<")
        case .playPause:   return .space
        case .next:        return .char(">")
        case .seekBack:    return .char("[")
        case .seekForward: return .char("]")
        }
    }

    /// The shell global this cell stands for; nil for the Now tab's own seek.
    var global: GlobalAction? {
        switch self {
        case .previous:  return .prev
        case .playPause: return .playPause
        case .next:      return .next
        case .seekBack, .seekForward: return nil
        }
    }

    /// Seconds to seek by, nil for the non-seek cells.
    var seekOffset: Double? {
        switch self {
        case .seekBack:    return -Self.seekStep
        case .seekForward: return Self.seekStep
        default:           return nil
        }
    }

    /// The action-runner label the key's own path uses (toast text and the
    /// starting-label rule key off it).
    var actionLabel: String {
        switch self {
        case .previous:  return "Back"
        case .playPause: return "Play/pause"
        case .next:      return "Skip"
        case .seekBack, .seekForward: return "Seek"
        }
    }

    /// The cell's text. Play/pause shows what pressing it will do.
    func label(playing: Bool) -> String {
        switch self {
        case .previous:    return "\u{25C0}\u{25C0} Prev"
        case .playPause:   return playing ? "Pause" : "Play"
        case .next:        return "Next \u{25B6}\u{25B6}"
        case .seekBack:    return "-30s"
        case .seekForward: return "+30s"
        }
    }
}

/// Space on a SpanDAC output. The wire has play and pause, not a toggle, so the
/// current state decides which one this press means.
func spanDACTogglePlayPause(_ client: SourceAppClient) throws {
    if try client.control.status().playback == "playing" {
        try client.control.pause()
    } else {
        try client.control.resume()
    }
}

/// Previous, play/pause and next, routed exactly as the shell's `<`, Space and
/// `>` route them. The shell calls this for its keys and the Now tab's control
/// row calls it for its cells, so there is one body for each. Seek is not here:
/// it is the Now scene's own `seek(by:)`.
func performSourceTransport(_ t: SpanDACTransport, routing: RoutingCoordinator,
                            musicApp: () throws -> Void = {}) throws {
    switch t {
    case .previous:
        try routing.perform(.previous, musicApp: musicApp,
                            source: { try $0.control.previous() }, unaffected: {})
    case .playPause:
        try routing.perform(.playPause, musicApp: musicApp,
                            source: { try spanDACTogglePlayPause($0) }, unaffected: {})
    case .next:
        try routing.perform(.next, musicApp: musicApp,
                            source: { try $0.control.next() }, unaffected: {})
    case .seekBack, .seekForward:
        break
    }
}

/// Which source the Now tab's cover comes from for a SpanDAC song.
enum BridgeCoverSource: Equatable {
    /// A fetchable http(s) artwork URL, through the ArtworkStore as before.
    case remote(String)
    /// No usable URL but a persistent ID: pull the cover out of the Music
    /// library by AppleScript, as the Library tab does. Carries the 16-digit
    /// uppercase hex AppleScript's `persistent ID is` takes, converted from the
    /// signed-decimal alias SpanDAC sends.
    case library(persistentID: String)
    /// Nothing to go on: the gradient.
    case none
}

/// The art rung, pure. A non-http artwork URL (`musicKit://artwork/transient/...`)
/// cannot be fetched, so it is ignored rather than handed to the fetcher. A
/// persistent ID that does not convert (`persistentIDHex(fromAlias:)`) is
/// treated as absent; the hex also keeps the temp file name safe.
func bridgeCoverSource(artworkURL: String?, persistentID: String?) -> BridgeCoverSource {
    if let url = artworkURL {
        let lower = url.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return .remote(url) }
    }
    if let alias = persistentID, let hex = persistentIDHex(fromAlias: alias) {
        return .library(persistentID: hex)
    }
    return .none
}
