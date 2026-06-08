// tools/music/Sources/TUI/Shell/ShellFrame.swift
import Foundation

enum BarTier { case full, compact, minimal, bare }
enum TabStyle { case full, digits, hidden }

/// Geometry for the unified shell, chosen by terminal height so the design
/// degrades gracefully instead of collapsing. Scenes render only into the body
/// region (bodyY .. bodyY+bodyHeight-1) and never need to know the tier.
struct ShellFrame {
    let width: Int
    let height: Int
    let barTier: BarTier
    let tabStyle: TabStyle
    let labelY: Int        // app label "music"
    let tabsY: Int         // tab strip row (0 when hidden)
    let ruleY: Int         // accent rule
    let bodyY: Int         // first body row
    let bodyHeight: Int    // rows available for the active scene body
    let barY: Int          // first row of the bar band (== footerY when barHeight 0)
    let barHeight: Int
    let footerY: Int       // last row
}

func shellLayout(width: Int, height: Int) -> ShellFrame {
    // The persistent now-playing bar was removed (playback lives on the Now tab),
    // so there is no bar band — the body extends down to just above the footer.
    // Height still drives the tab style (full names vs digits vs hidden).
    let tier: BarTier
    let tabStyle: TabStyle
    switch height {
    case 19...:   tier = .full;    tabStyle = .full
    case 15...18: tier = .minimal; tabStyle = .digits
    default:      tier = .bare;    tabStyle = .hidden
    }
    let barHeight = 0

    let labelY = 1
    let showTabs = tabStyle != .hidden
    let tabsY = showTabs ? 2 : 0
    let ruleY = showTabs ? 3 : 2
    let bodyY = ruleY + 1
    let footerY = max(bodyY, height)
    let barY = footerY - barHeight
    let bodyHeight = max(0, barY - bodyY)

    return ShellFrame(
        width: width, height: height,
        barTier: tier, tabStyle: tabStyle,
        labelY: labelY, tabsY: tabsY, ruleY: ruleY,
        bodyY: bodyY, bodyHeight: bodyHeight,
        barY: barY, barHeight: barHeight, footerY: footerY
    )
}
