import Foundation

struct MixerSpeaker {
    let name: String
    var volume: Int
}

func runVolumeMixer(
    speakers: inout [MixerSpeaker],
    onVolumeChange: (String, Int) -> Void
) {
    let terminal = TerminalState.shared
    terminal.enterRawMode()
    defer { terminal.exitRawMode() }

    var cursor = 0
    let barWidth = 30

    func render() {
        var out = ANSICode.cursorHome + ANSICode.clearScreen

        // Header
        out += "\n"
        out += "  \(ANSICode.bold)\(ANSICode.cyan)♫  Volume Mixer\(ANSICode.reset)\n"
        out += "  \(ANSICode.dim)\(String(repeating: "─", count: 20))\(ANSICode.reset)\n\n"

        let maxNameLen = speakers.map(\.name.count).max() ?? 0

        for (i, spk) in speakers.enumerated() {
            let isCursor = i == cursor
            let pointer = isCursor ? "\(ANSICode.cyan)▸\(ANSICode.reset)" : " "
            let highlight = isCursor ? ANSICode.bold : ""
            let resetH = isCursor ? ANSICode.reset : ""
            let padded = spk.name.padding(toLength: maxNameLen, withPad: " ", startingAt: 0)
            let filled = Int(Double(spk.volume) / 100.0 * Double(barWidth))
            let bar = "\(ANSICode.green)\(String(repeating: "█", count: filled))\(ANSICode.reset)\(ANSICode.dim)\(String(repeating: "░", count: barWidth - filled))\(ANSICode.reset)"
            let volStr = String(format: "%3d%%", spk.volume)
            out += " \(pointer) \(highlight)\(padded)\(resetH)  \(bar) \(volStr)\n"
        }

        // Footer
        out += "\n  \(ANSICode.dim)╭──────────────────────────────────────────────╮\(ANSICode.reset)\n"
        out += "  \(ANSICode.dim)│\(ANSICode.reset) ↑↓ speaker  ←→ volume ±5  0-9 quick-set  q quit \(ANSICode.dim)│\(ANSICode.reset)\n"
        out += "  \(ANSICode.dim)╰──────────────────────────────────────────────╯\(ANSICode.reset)\n"

        print(out, terminator: "")
        fflush(stdout)
    }

    render()

    var digitBuffer = ""

    while true {
        guard let key = KeyPress.read() else { continue }
        switch key {
        case .up:
            cursor = max(0, cursor - 1)
            digitBuffer = ""
        case .down:
            cursor = min(speakers.count - 1, cursor + 1)
            digitBuffer = ""
        case .left:
            speakers[cursor].volume = max(0, speakers[cursor].volume - 5)
            onVolumeChange(speakers[cursor].name, speakers[cursor].volume)
            digitBuffer = ""
        case .right:
            speakers[cursor].volume = min(100, speakers[cursor].volume + 5)
            onVolumeChange(speakers[cursor].name, speakers[cursor].volume)
            digitBuffer = ""
        case .char(let c) where c.isNumber:
            digitBuffer.append(c)
            if digitBuffer.count >= 2 {
                if let vol = Int(digitBuffer) {
                    speakers[cursor].volume = min(100, max(0, vol))
                    onVolumeChange(speakers[cursor].name, speakers[cursor].volume)
                }
                digitBuffer = ""
            }
        case .char("q"), .escape:
            return
        default:
            digitBuffer = ""
        }
        render()
    }
}
