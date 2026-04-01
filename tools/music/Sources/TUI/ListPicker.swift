import Foundation

func runListPicker(title: String, items: [String]) -> Int? {
    let terminal = TerminalState.shared
    terminal.enterRawMode()
    defer { terminal.exitRawMode() }

    var cursor = 0

    func render() {
        var out = ANSICode.cursorHome + ANSICode.clearScreen
        out += "\(ANSICode.bold)\(title)\(ANSICode.reset)\n\n"

        let pageSize = 20
        let start = max(0, cursor - pageSize / 2)
        let end = min(items.count, start + pageSize)

        for i in start..<end {
            let highlight = i == cursor ? ANSICode.inverse : ""
            let resetH = i == cursor ? ANSICode.reset : ""
            out += " \(highlight) \(items[i]) \(resetH)\n"
        }

        out += "\n\(ANSICode.dim)↑↓ navigate  ⏎ select  q quit\(ANSICode.reset)"
        print(out, terminator: "")
        fflush(stdout)
    }

    render()

    while true {
        guard let key = KeyPress.read() else { continue }
        switch key {
        case .up: cursor = max(0, cursor - 1)
        case .down: cursor = min(items.count - 1, cursor + 1)
        case .enter: return cursor
        case .char("q"), .escape: return nil
        default: break
        }
        render()
    }
}
