// Apple Music stations play by rewriting the station's REST share URL from
// https:// to music:// and handing it to `open` — probed and audio-verified
// 2026-07-15. The https:// form opens Safari; the scheme IS the mechanism.
// No AppleScript, no Accessibility, no MusicKit; the AirPlay route survives.
import Foundation

struct Station: Codable, Equatable {
    let id: String          // ra.978194965
    let name: String
    let url: String         // the https:// share URL — the play handle
    let isLive: Bool?       // nil = unknown; observed at play time (no duration ⇒ live)
    let artworkURL: String?
}

enum StationError: Error, Equatable {
    case notAStationURL(String)
}

protocol Opener {
    func open(_ url: String) throws
}

/// Hands the URL to macOS via /usr/bin/open. The only impure part of this file.
struct SystemOpener: Opener {
    func open(_ url: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = [url]
        try p.run()
        p.waitUntilExit()
    }
}

/// https://music.apple.com/{sf}/station/{slug}/{id} -> music://…
/// nil unless the host is music.apple.com AND the path is a /station/ path.
/// Both checks matter: music:// on an album URL would silently play an album.
func stationPlayURL(_ shareURL: String) -> String? {
    guard let comps = URLComponents(string: shareURL.trimmingCharacters(in: .whitespaces)),
          let host = comps.host, host == "music.apple.com",
          comps.path.contains("/station/"),
          let scheme = comps.scheme, ["http", "https", "music"].contains(scheme)
    else { return nil }
    var out = comps
    out.scheme = "music"
    return out.string
}

/// Pull the id and slug out of a station share URL. Pure; works even when the
/// catalog API cannot resolve the station (the BBC Radio 1 case).
func parseStationURL(_ shareURL: String) -> (id: String, slug: String)? {
    guard let comps = URLComponents(string: shareURL), comps.host == "music.apple.com" else { return nil }
    let segs = comps.path.split(separator: "/").map(String.init)
    guard let sIdx = segs.firstIndex(of: "station"), segs.count > sIdx + 2 else { return nil }
    return (id: segs[sIdx + 2], slug: segs[sIdx + 1])
}

/// "bbc-radio-1" -> "Bbc Radio 1". Percent-escapes are decoded first so
/// "apple-m%C3%BAsica-uno" -> "Apple Música Uno". Used only when the API can't
/// resolve the id — a best-effort label, never presented as authoritative.
func displayNameFromSlug(_ slug: String) -> String {
    let decoded = slug.removingPercentEncoding ?? slug
    return decoded.split(separator: "-")
        .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        .joined(separator: " ")
}

func playStation(_ station: Station, via opener: Opener) throws {
    guard let url = stationPlayURL(station.url) else {
        throw StationError.notAStationURL(station.url)
    }
    try opener.open(url)
}
