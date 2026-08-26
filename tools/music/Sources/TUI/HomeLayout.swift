// Home's layout arithmetic and text composition, kept pure so the dashboard is
// testable without a terminal.
//
// Row budgets are measured against ShellFrame.bodyHeight, never against raw
// terminal height: shellLayout reserves labelY/tabsY/ruleY above the body and
// the footer below it, so bodyHeight == height - 4.
import Foundation

/// Same breakpoint as the Now tab, so the two designed scenes agree on when a
/// second pane is affordable.
func homeIsTwoPane(width: Int) -> Bool { width >= 92 }

/// Home's left column is the primary content rail rather than a metadata block,
/// so it is the dominant side: wider than the Now tab's 44...54.
func homeLeftWidth(frameWidth: Int) -> Int {
    let minWidth = 92.0, maxWidth = 180.0
    let floorW = 56.0, capW = 88.0
    let t = min(1.0, max(0.0, (Double(frameWidth) - minWidth) / (maxWidth - minWidth)))
    return Int((floorW + (capW - floorW) * t).rounded())
}

/// The footer names the action the current row can actually perform. "Play/Open"
/// was ambiguous exactly where the tab needs to be honest: a station listens, an
/// album only opens a read-only track list.
///
/// `canGoBack` and `canRefresh` are separate flags, not one "depth" concept,
/// because they are governed by different rules: back is available at any
/// level below Home, while refresh is guarded to the top level ONLY (see
/// HomeScene.handle) because refresh() resets the whole navigation stack —
/// offering it inside a rail or track list would silently teleport the user
/// back to Home. The footer must advertise only what the current level will
/// actually do with the key, so `r Refresh` is appended solely when
/// `canRefresh` is true.
func homeFooterHint(_ selection: HomeSelection?, canGoBack: Bool, canRefresh: Bool) -> String {
    let back = canGoBack ? "  \u{2190} Back" : ""
    let refresh = canRefresh ? "  r Refresh" : ""
    switch selection {
    case .item(let item):
        switch item.detail {
        case .station:
            return "\u{2191}\u{2193} Move  Enter Listen" + refresh + back
        case .album, .playlist:
            return "\u{2191}\u{2193} Move  Enter Browse" + refresh + back
        case .song:
            return "\u{2191}\u{2193} Move" + back
        }
    case .viewAll:
        return "\u{2191}\u{2193} Move  Enter View all" + refresh + back
    case nil:
        return "\u{2191}\u{2193} Move" + refresh + back
    }
}

/// The panel's metadata line. nil means render nothing rather than a blank block.
func homePanelMeta(_ detail: HomeItemDetail) -> String? {
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
func homePanelBadge(_ detail: HomeItemDetail) -> String {
    switch detail {
    case .station(let isLive): return isLive ? "LIVE" : "STATION"
    case .album:               return "ALBUM"
    case .playlist:            return "PLAYLIST"
    case .song:                return "SONG"
    }
}

/// The panel's single primary action. Obeys the same rule as the play marker:
/// never promise an action the platform cannot deliver.
func homePanelAction(_ selection: HomeSelection) -> String {
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
func homeWrapText(_ s: String, to width: Int, maxLines: Int) -> [String] {
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
            lines[lines.count - 1] = homeMarkClipped(lines[lines.count - 1], width: width)
            return lines
        }
    }
    if !line.isEmpty, lines.count < maxLines { lines.append(line) }
    return lines
}

/// Marks a wrapped line as clipped, reusing truncText's own ellipsis rule
/// rather than inventing a second one.
private func homeMarkClipped(_ line: String, width: Int) -> String {
    guard !line.hasSuffix("\u{2026}") else { return line }
    return truncText(line + "\u{2026}", to: width)
}

/// The left pane's two-column split. Subtitle gets a third of the usable width
/// when present, the title takes the rest — which is what removed the old hard
/// 40-column title cap.
func homeRowColumns(width: Int, hasSubtitle: Bool) -> (nameW: Int, subW: Int) {
    let subW = hasSubtitle ? max(0, (width - 8) / 3) : 0
    return (max(12, width - 8 - subW), subW)
}
