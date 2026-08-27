// Discover's layout arithmetic and text composition, kept pure so the dashboard is
// testable without a terminal.
//
// Row budgets are measured against ShellFrame.bodyHeight, never against raw
// terminal height: shellLayout reserves labelY/tabsY/ruleY above the body and
// the footer below it, so bodyHeight == height - 4.
import Foundation

/// Same breakpoint as the Now tab, so the two designed scenes agree on when a
/// second pane is affordable.
func discoverIsTwoPane(width: Int) -> Bool { width >= 92 }

/// Discover's left column is the primary content rail rather than a metadata block,
/// so it is the dominant side: wider than the Now tab's 44...54.
func discoverLeftWidth(frameWidth: Int) -> Int {
    let minWidth = 92.0, maxWidth = 180.0
    let floorW = 56.0, capW = 88.0
    let t = min(1.0, max(0.0, (Double(frameWidth) - minWidth) / (maxWidth - minWidth)))
    return Int((floorW + (capW - floorW) * t).rounded())
}

/// The footer names the action the current row can actually perform. "Play/Open"
/// was ambiguous exactly where the tab needs to be honest: a station listens, an
/// album only opens a read-only track list.
///
/// `p` is advertised only on rows where the handler actually acts on it — an
/// album/playlist rail row ("Play all") and a track row inside a drill-in
/// ("Play all" there too — DiscoverScene's `p` on a track row plays the whole
/// container, never just that track). Enter does NOT play on a track row:
/// there is no per-track play path (deferred), so a track row's footer is
/// bare movement plus Back. Station rows and `View all` rows never gain `p`:
/// DiscoverScene's `p` handler is a no-op on both, and a key the handler
/// ignores must not be advertised — this repo has already shipped that exact
/// bug once.
///
/// `canGoBack` and `canRefresh` are separate flags, not one "depth" concept,
/// because they are governed by different rules: back is available at any
/// level below Discover, while refresh is guarded to the top level ONLY (see
/// DiscoverScene.handle) because refresh() resets the whole navigation stack —
/// offering it inside a rail or track list would silently teleport the user
/// back to Discover. The footer must advertise only what the current level will
/// actually do with the key, so `r Refresh` is appended solely when
/// `canRefresh` is true.
func discoverFooterHint(_ selection: DiscoverSelection?, canGoBack: Bool, canRefresh: Bool) -> String {
    let back = canGoBack ? "  \u{2190} Back" : ""
    let refresh = canRefresh ? "  r Refresh" : ""
    switch selection {
    case .item(let item):
        switch item.detail {
        case .station:
            return "\u{2191}\u{2193} Move  Enter Listen" + refresh + back
        case .album, .playlist:
            return "\u{2191}\u{2193} Move  Enter Browse  p Play" + refresh + back
        case .song:
            return "\u{2191}\u{2193} Move" + back
        }
    case .viewAll:
        return "\u{2191}\u{2193} Move  Enter View all" + refresh + back
    case nil:
        return "\u{2191}\u{2193} Move" + refresh + back
    }
}

/// Whether `→` should act on this selection. → drills in and never plays: the
/// convention LibraryScene and PlaylistsScene both document. A station's Enter
/// means Listen, so → must not fire it, or an arrow key would start playback
/// and pull Music.app to the front.
func discoverRightArrowActivates(_ selection: DiscoverSelection?) -> Bool {
    switch selection {
    case .item(let item):
        switch item.detail {
        case .album, .playlist: return true
        case .station, .song:   return false
        }
    case .viewAll:  return true
    case nil:       return false
    }
}

/// The panel's metadata line. nil means render nothing rather than a blank block.
func discoverPanelMeta(_ detail: DiscoverItemDetail) -> String? {
    switch detail {
    case .station:
        return nil
    case .album(let count, let year, let genre):
        let parts: [String?] = [count.map { "\($0) track\($0 == 1 ? "" : "s")" },
                                year.map(String.init),
                                genre]
        let joined = parts.compactMap { $0 }
        return joined.isEmpty ? nil : joined.joined(separator: " \u{00B7} ")
    case .playlist(let description):
        // Playlists carry no trackCount at all, so description is the honest
        // equivalent. User-authored playlists carry neither. An empty string is
        // treated as absent: the API can return {"standard": ""} for a present
        // but empty field, and returning Some("") here would render a blank
        // line, which is exactly what the optional exists to prevent.
        return description.flatMap { $0.isEmpty ? nil : $0 }
    case .song:
        return nil
    }
}

/// PERSONAL is deliberately absent: `ra.u-` is an observed id prefix, not a
/// documented API contract, and not strong enough to become product language.
func discoverPanelBadge(_ detail: DiscoverItemDetail) -> String {
    switch detail {
    case .station(let isLive): return isLive ? "LIVE" : "STATION"
    case .album:               return "ALBUM"
    case .playlist:            return "PLAYLIST"
    case .song:                return "SONG"
    }
}

/// The panel's single primary action. Obeys the same rule as the play marker:
/// never promise an action the platform cannot deliver.
func discoverPanelAction(_ selection: DiscoverSelection) -> String {
    switch selection {
    case .item(let item):
        switch item.detail {
        case .station:          return "Enter  Listen"
        case .album, .playlist: return "Enter  Browse tracks"
        case .song:              return ""
        }
    case .viewAll(let rail):
        return "Enter  View all \(rail.items.count)"
    }
}

/// Word-wrap for the panel's description block. Anything wider than the panel
/// is truncated rather than carried through: playlist descriptions are API
/// text, and one unbroken token (a URL, a hashtag run) would otherwise overrun
/// the column, which renderPanel's line writer does not clamp.
///
/// When the description runs past `maxLines`, the last kept line gets a
/// trailing ellipsis via truncText, the same marker every other cut in this
/// file uses — a wrap that silently drops the tail reads as complete text
/// rather than as clipped.
func discoverWrapText(_ s: String, to width: Int, maxLines: Int) -> [String] {
    guard width > 0, maxLines > 0 else { return [] }
    var lines: [String] = []
    var line = ""
    for word in s.split(separator: " ") {
        let w = truncText(String(word), to: width)
        let candidate = line.isEmpty ? w : line + " " + w
        if candidate.count <= width { line = candidate; continue }
        if !line.isEmpty { lines.append(line) }
        line = w
        if lines.count == maxLines {
            lines[lines.count - 1] = discoverMarkClipped(lines[lines.count - 1], width: width)
            return lines
        }
    }
    if !line.isEmpty, lines.count < maxLines { lines.append(line) }
    return lines
}

/// Marks a wrapped line as clipped, reusing truncText's own ellipsis rule
/// rather than inventing a second one.
private func discoverMarkClipped(_ line: String, width: Int) -> String {
    guard !line.hasSuffix("\u{2026}") else { return line }
    return truncText(line + "\u{2026}", to: width)
}

/// The left pane's two-column split. Subtitle gets a third of the usable width
/// when present, the title takes the rest — which is what removed the old hard
/// 40-column title cap.
func discoverRowColumns(width: Int, hasSubtitle: Bool) -> (nameW: Int, subW: Int) {
    let subW = hasSubtitle ? max(0, (width - 8) / 3) : 0
    return (max(12, width - 8 - subW), subW)
}
