import Foundation

// MARK: - Metadata

/// Per-playlist metadata. Optional fields are `nil` until enrichment loads
/// them; the UI renders a reserved placeholder so values land without shifting
/// layout.
struct PlaylistMeta {
    let name: String
    var trackCount: Int?
    var durationSec: Int?
    var isSmart: Bool?
    var specialKind: String?
    var loaded: Bool = false
}

enum PlaylistBadge: Equatable {
    case smart, recent, apple, none
}

private let recentPlaylistNames: Set<String> = ["Recently Played", "Top 25 Most Played"]

/// Pure badge derivation. recent > apple > smart > none.
/// `isSubscription` marks Apple-curated playlists added to the library
/// (AppleScript class `subscription playlist`) — they update on Apple's
/// schedule and are read-only.
func playlistBadge(name: String, isSmart: Bool, specialKind: String, isSubscription: Bool = false) -> PlaylistBadge {
    if recentPlaylistNames.contains(name) { return .recent }
    if isSubscription { return .apple }
    if isSmart { return .smart }
    return .none
}

/// Format a duration in seconds as "Hh Mm" (or "Mm" under an hour).
func formatPlaylistDuration(_ seconds: Int) -> String {
    let totalMin = max(0, seconds) / 60
    let h = totalMin / 60
    let m = totalMin % 60
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}

// MARK: - Zone geometry

enum PlaylistZoneMode { case one, two, three }

struct PlaylistZones {
    let mode: PlaylistZoneMode
    let railX: Int
    let railWidth: Int
    let heroX: Int
    let heroWidth: Int
    let rightX: Int?      // nil unless mode == .three
    let rightWidth: Int
}

/// Compute zone geometry from terminal width. Pure.
/// >=138: three zones; 96..137: rail+hero; <96: rail + compact hero.
func playlistZones(width: Int) -> PlaylistZones {
    let railX = 3
    let gutter = 3
    if width >= 138 {
        let railWidth = 34
        let heroX = railX + railWidth + gutter
        let heroWidth = min(54, (width - heroX - gutter - railX) / 2 + 6)
        let rightX = heroX + heroWidth + gutter
        let rightWidth = min(52, width - rightX - 2)
        return PlaylistZones(mode: .three, railX: railX, railWidth: railWidth,
                             heroX: heroX, heroWidth: heroWidth,
                             rightX: rightX, rightWidth: max(0, rightWidth))
    } else if width >= 96 {
        let railWidth = 34
        let heroX = railX + railWidth + gutter
        let heroWidth = max(0, width - heroX - 2)
        return PlaylistZones(mode: .two, railX: railX, railWidth: railWidth,
                             heroX: heroX, heroWidth: heroWidth,
                             rightX: nil, rightWidth: 0)
    } else {
        let railWidth = min(30, max(18, width / 2))
        let heroX = railX + railWidth + gutter
        let heroWidth = max(0, width - heroX - 2)
        return PlaylistZones(mode: .one, railX: railX, railWidth: railWidth,
                             heroX: heroX, heroWidth: heroWidth,
                             rightX: nil, rightWidth: 0)
    }
}

// MARK: - Gradient block (deterministic identity, not real artwork)

private let gradientGlyphs = "\u{2588}\u{2593}\u{2592}\u{2591}"  // full/dark/medium/light shade

/// Build a deterministic block of `height` strings, each `width` glyphs,
/// seeded by the playlist name. No color codes here — caller wraps with color.
func gradientBlock(name: String, width: Int, height: Int) -> [String] {
    guard width > 0, height > 0 else { return [] }
    var seed = 5381
    for b in name.unicodeScalars { seed = ((seed << 5) &+ seed) &+ Int(b.value) }
    let glyphs = Array(gradientGlyphs)
    var rows: [String] = []
    for r in 0..<height {
        var line = ""
        for c in 0..<width {
            let idx = abs((seed &+ r &* 31 &+ c &* 7)) % glyphs.count
            line.append(glyphs[idx])
        }
        rows.append(line)
    }
    return rows
}

// MARK: - Rail name truncation

/// Truncate a playlist name to exactly fit `nameWidth` columns, ellipsis if cut.
func railName(_ name: String, nameWidth: Int) -> String {
    guard nameWidth > 0 else { return "" }
    if name.count <= nameWidth { return name }
    if nameWidth == 1 { return "\u{2026}" }
    return String(name.prefix(nameWidth - 1)) + "\u{2026}"
}
