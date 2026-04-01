import Foundation

struct MultiSelectItem {
    let label: String
    let sublabel: String
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
    onToggle: ((Int, Bool) -> Void)? = nil
) -> MultiSelectAction {
    let terminal = TerminalState.shared
    terminal.enterRawMode()
    defer { terminal.exitRawMode() }

    var cursor = 0
    let pageSize = 20

    func selectedIndices() -> [Int] {
        items.enumerated().compactMap { $0.element.selected ? $0.offset : nil }
    }

    func render() {
        var out = ANSICode.cursorHome + ANSICode.clearScreen

        // Header
        out += "\n"
        out += "  \(ANSICode.bold)\(ANSICode.cyan)♫  \(title)\(ANSICode.reset)\n"
        out += "  \(ANSICode.dim)\(String(repeating: "─", count: min(60, title.count + 6)))\(ANSICode.reset)\n\n"

        let start = max(0, cursor - pageSize / 2)
        let end = min(items.count, start + pageSize)

        for i in start..<end {
            let item = items[i]
            let marker = item.selected ? "\(ANSICode.green)●\(ANSICode.reset)" : "\(ANSICode.dim)○\(ANSICode.reset)"
            let isCursor = i == cursor
            let highlight = isCursor ? ANSICode.inverse : ""
            let resetH = isCursor ? ANSICode.reset : ""
            let pointer = isCursor ? "\(ANSICode.cyan)▸\(ANSICode.reset)" : " "
            let num = String(format: "%2d", i + 1)
            let sub = item.sublabel.isEmpty ? "" : "\n       \(ANSICode.dim)\(item.sublabel)\(ANSICode.reset)"
            out += " \(pointer) \(marker) \(highlight) \(num). \(item.label) \(resetH)\(sub)\n"
        }

        // Scroll indicator
        if items.count > pageSize {
            let pct = items.count > 1 ? Int(Double(cursor) / Double(items.count - 1) * 100) : 0
            out += "\n  \(ANSICode.dim)[\(start + 1)–\(end) of \(items.count)] \(pct)%\(ANSICode.reset)\n"
        }

        // Footer
        let selected = selectedIndices()
        out += "\n  \(ANSICode.dim)╭─────────────────────────────────────────────╮\(ANSICode.reset)\n"
        out += "  \(ANSICode.dim)│\(ANSICode.reset) ↑↓ navigate  ␣ select  ⏎ confirm  q quit \(ANSICode.dim)│\(ANSICode.reset)\n"
        if !actions.isEmpty {
            var actionLine = "  \(ANSICode.dim)│\(ANSICode.reset) "
            for a in actions {
                actionLine += "\(ANSICode.cyan)\(a.key)\(ANSICode.reset) \(a.label)  "
            }
            actionLine += String(repeating: " ", count: max(0, 45 - actions.reduce(0) { $0 + 4 + $1.label.count }))
            actionLine += "\(ANSICode.dim)│\(ANSICode.reset)"
            out += actionLine + "\n"
        }
        out += "  \(ANSICode.dim)╰─────────────────────────────────────────────╯\(ANSICode.reset)\n"
        if !selected.isEmpty {
            out += "  \(ANSICode.green)\(selected.count) selected\(ANSICode.reset)\n"
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
        case .char("q"), .escape:
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
        default:
            break
        }
        render()
    }
}
