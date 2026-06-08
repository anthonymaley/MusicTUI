// tools/music/Sources/TUI/Shell/ShellChrome.swift
import Foundation

/// App label + accent rule. Tab strip is rendered separately so it can be
/// hidden in the Bare tier.
func renderShellChrome(frame: ShellFrame) -> String {
    var out = ANSICode.cursorHome
    out += ANSICode.moveTo(row: frame.labelY, col: 3) + ANSICode.clearLine
    out += "\(ANSICode.dim)music\(ANSICode.reset)"
    out += ANSICode.moveTo(row: frame.ruleY, col: 3) + ANSICode.clearLine
    out += "\(ANSICode.dim)\(String(repeating: "\u{2500}", count: min(40, frame.width - 4)))\(ANSICode.reset)"
    return out
}

/// Horizontal scene tabs. `.full` shows names; `.digits` shows 1·2·3; `.hidden`
/// renders nothing. The active tab is highlighted in cyan/bold.
func renderTabStrip(active: SceneID, tabs: [(id: SceneID, title: String)], frame: ShellFrame) -> String {
    guard frame.tabStyle != .hidden, frame.tabsY > 0 else { return "" }
    var out = ANSICode.moveTo(row: frame.tabsY, col: 3) + ANSICode.clearLine
    out += "\(ANSICode.bold)\(ANSICode.cyan)\u{266B}\(ANSICode.reset)  "
    for (i, tab) in tabs.enumerated() {
        let isActive = tab.id == active
        let label: String
        switch frame.tabStyle {
        case .full:   label = tab.title
        case .digits: label = "\(i + 1)"
        case .hidden: label = ""
        }
        if isActive {
            out += "\(ANSICode.bold)\(ANSICode.cyan)\(label)\(ANSICode.reset)"
        } else {
            out += "\(ANSICode.dim)\(label)\(ANSICode.reset)"
        }
        if i < tabs.count - 1 { out += frame.tabStyle == .digits ? "\(ANSICode.dim)·\(ANSICode.reset)" : "   " }
    }
    return out
}
