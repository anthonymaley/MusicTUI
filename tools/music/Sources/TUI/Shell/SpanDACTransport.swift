// tools/music/Sources/TUI/Shell/SpanDACTransport.swift
import Foundation

/// The transport the shell's global `<`, Space and `>` run on a SpanDAC output.
/// Each lands in `performSourceTransport`, the single body for it.
/// (Seek is the Now scene's own `seek(by:)`, so it is not here.)
enum SpanDACTransport: Equatable {
    case previous, playPause, next
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
/// `>` route them: one body for each key.
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
