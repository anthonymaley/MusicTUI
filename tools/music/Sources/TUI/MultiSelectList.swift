import Foundation
import Darwin

struct MultiSelectItem {
    let label: String
    var sublabel: String
    var selected: Bool
}

enum MultiSelectAction {
    case confirmed([Int])
    case played(Int)
    case shuffled([Int])
    case addedToLibrary([Int])
    case createPlaylist([Int])
    case cancelled
}

func runMultiSelectList(
    title: String,
    items: inout [MultiSelectItem],
    actions: [(key: Character, label: String, action: (Int, [Int]) -> MultiSelectAction)] = [],
    onToggle: ((Int, Bool) -> Void)? = nil,
    onAdjust: ((Int, Int) -> String)? = nil  // (index, delta) -> new sublabel
) -> MultiSelectAction {
    let terminal = TerminalState.shared
    terminal.enterRawMode()
    defer { terminal.exitRawMode() }

    var cursor = 0
    var scrollOffset = 0

    let hasSpeakerMode = onAdjust != nil

    // Column widths for speaker mode
    let nameW = 28
    let gapW = 2
    let barW = 20
    let gap2W = 1

    func selectedIndices() -> [Int] {
        items.enumerated().compactMap { $0.element.selected ? $0.offset : nil }
    }

    func parseVolume(_ sublabel: String) -> Int {
        if let range = sublabel.range(of: "vol: "),
           let vol = Int(sublabel[range.upperBound...].trimmingCharacters(in: .whitespaces)) {
            return vol
        }
        return 0
    }

    func render() {
        let frame = ScreenFrame.current()
        let maxVisible = max(1, frame.statusY - frame.bodyY - 4)

        // Adjust scroll offset
        if cursor < scrollOffset {
            scrollOffset = cursor
        } else if cursor >= scrollOffset + maxVisible {
            scrollOffset = cursor - maxVisible + 1
        }

        let visibleEnd = min(items.count, scrollOffset + maxVisible)

        // Status text
        let sel = selectedIndices()
        let statusText = sel.isEmpty ? "0 selected" : "\(sel.count) selected"

        // Footer text
        let footerText: String
        if hasSpeakerMode {
            footerText = "\(ANSICode.dim)Controls\(ANSICode.reset)  ↑↓ Navigate   Space Toggle   ←→ Volume   Enter Confirm   q Quit"
        } else {
            var line = "\(ANSICode.dim)Controls\(ANSICode.reset)  ↑↓ Navigate   Space Select   Enter Confirm"
            for a in actions {
                line += "   \(a.key) \(a.label)"
            }
            line += "   q Quit"
            footerText = line
        }

        var out = renderShell(title: title, status: statusText, footer: footerText)

        let tableX = 3
        let tableY = frame.bodyY + 2

        // Item rows
        for i in scrollOffset..<visibleEnd {
            let item = items[i]
            let row = tableY + (i - scrollOffset)
            out += ANSICode.moveTo(row: row, col: tableX)

            let pointer = i == cursor ? "\(ANSICode.cyan)▶\(ANSICode.reset)" : " "
            let marker = item.selected ? "\(ANSICode.green)●\(ANSICode.reset)" : "\(ANSICode.dim)○\(ANSICode.reset)"

            if hasSpeakerMode {
                let vol = parseVolume(item.sublabel)
                let nameStr = truncText(item.label, to: nameW)
                let padded = nameStr.padding(toLength: nameW, withPad: " ", startingAt: 0)
                let pct = String(format: "%3d%%", vol)

                if item.selected {
                    // Active: show bar + percent
                    let bar = meterBar(value: vol, width: barW)
                    out += "\(pointer) \(marker) \(padded)  \(bar) \(pct)"
                } else {
                    // Inactive: percent only, no bar
                    let spacer = String(repeating: " ", count: gapW + barW + gap2W)
                    out += "\(pointer) \(marker) \(padded)\(spacer) \(pct)"
                }
            } else {
                let num = String(format: "%02d", i + 1)
                out += "\(pointer) \(marker) \(num). \(truncText(item.label, to: frame.width - 16))"
            }
        }

        // Right summary pane for speaker mode
        if hasSpeakerMode {
            let paneX = 74
            if paneX < frame.width - 10 {
                let paneY = frame.bodyY
                out += ANSICode.moveTo(row: paneY, col: paneX)
                out += "\(ANSICode.bold)Selected\(ANSICode.reset)"
                out += ANSICode.moveTo(row: paneY + 1, col: paneX)
                out += "\(ANSICode.dim)\(String(repeating: "─", count: 8))\(ANSICode.reset)"

                var row = paneY + 3
                let maxPaneW = frame.width - paneX - 2
                for i in sel {
                    if row >= frame.statusY - 1 { break }
                    out += ANSICode.moveTo(row: row, col: paneX)
                    out += truncText(items[i].label, to: maxPaneW)
                    row += 1
                }
            }
        }

        print(out, terminator: "")
        fflush(stdout)
    }

    render()

    while true {
        guard let key = KeyPress.read() else { continue }
        switch key {
        case .up:
            cursor = max(0, cursor - 1)
        case .down:
            cursor = min(items.count - 1, cursor + 1)
        case .space:
            items[cursor].selected.toggle()
            onToggle?(cursor, items[cursor].selected)
        case .left:
            if let onAdjust = onAdjust {
                items[cursor].sublabel = onAdjust(cursor, -5)
            }
        case .right:
            if let onAdjust = onAdjust {
                items[cursor].sublabel = onAdjust(cursor, 5)
            }
        case .char("q"), .escape, .ctrlC:
            // Ctrl-C cancels like `q`: before it was named it fell through as a
            // dead control byte that matched no action.
            return .cancelled
        case .enter:
            let sel = selectedIndices()
            return .confirmed(sel.isEmpty ? [cursor] : sel)
        case .char(let c):
            for a in actions {
                if c == a.key {
                    return a.action(cursor, selectedIndices())
                }
            }
        case .pageUp, .home:
            cursor = 0
        case .pageDown, .end:
            cursor = max(0, items.count - 1)
        case .f7, .f9, .shiftTab:
            break
        }
        render()
    }
}
