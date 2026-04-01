import Foundation

func runListPicker(title: String, items: [String]) -> Int? {
    let terminal = TerminalState.shared
    terminal.enterRawMode()
    defer { terminal.exitRawMode() }

    var cursor = 0

    func render() {
        var out = ANSICode.cursorHome + ANSICode.clearScreen

        // Header
        out += "\n"
        out += "  \(ANSICode.bold)\(ANSICode.cyan)♫  \(title)\(ANSICode.reset)\n"
        out += "  \(ANSICode.dim)\(String(repeating: "─", count: min(60, title.count + 6)))\(ANSICode.reset)\n\n"

        let pageSize = 20
        let start = max(0, cursor - pageSize / 2)
        let end = min(items.count, start + pageSize)

        for i in start..<end {
            let isCursor = i == cursor
            let pointer = isCursor ? "\(ANSICode.cyan)▸\(ANSICode.reset)" : " "
            let highlight = isCursor ? ANSICode.inverse : ""
            let resetH = isCursor ? ANSICode.reset : ""
            out += " \(pointer) \(highlight) \(items[i]) \(resetH)\n"
        }

        // Scroll indicator
        if items.count > pageSize {
            let pct = items.count > 1 ? Int(Double(cursor) / Double(items.count - 1) * 100) : 0
            out += "\n  \(ANSICode.dim)[\(start + 1)–\(end) of \(items.count)] \(pct)%\(ANSICode.reset)\n"
        }

        // Footer
        out += "\n  \(ANSICode.dim)╭───────────────────────────────╮\(ANSICode.reset)\n"
        out += "  \(ANSICode.dim)│\(ANSICode.reset) ↑↓ navigate  ⏎ select  q quit \(ANSICode.dim)│\(ANSICode.reset)\n"
        out += "  \(ANSICode.dim)╰───────────────────────────────╯\(ANSICode.reset)\n"

        print(out, terminator: "")
        fflush(stdout)
    }

    render()

    while true {
        guard let key = KeyPress.read() else { continue }
        switch key {
        case .up: cursor = max(0, cursor - 1)
        case .down: cursor = min(items.count - 1, cursor + 1)
        case .enter, .space: return cursor
        case .char("q"), .escape: return nil
        default: break
        }
        render()
    }
}
