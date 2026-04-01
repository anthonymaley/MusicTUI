// Sources/TUI/Terminal.swift
import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct ANSICode {
    static let clearScreen = "\u{1B}[2J"
    static let cursorHome = "\u{1B}[H"
    static let hideCursor = "\u{1B}[?25l"
    static let showCursor = "\u{1B}[?25h"
    static let altScreenOn = "\u{1B}[?1049h"
    static let altScreenOff = "\u{1B}[?1049l"
    static let clearLine = "\u{1B}[2K"
    static let bold = "\u{1B}[1m"
    static let dim = "\u{1B}[2m"
    static let reset = "\u{1B}[0m"
    static let inverse = "\u{1B}[7m"
    static let green = "\u{1B}[32m"
    static let cyan = "\u{1B}[36m"
    static let yellow = "\u{1B}[33m"

    static func moveTo(row: Int, col: Int) -> String {
        "\u{1B}[\(row);\(col)H"
    }
}

enum KeyPress {
    case up, down, left, right
    case enter, space, escape
    case char(Character)

    static func read() -> KeyPress? {
        var buf = [UInt8](repeating: 0, count: 3)
        let n = Darwin.read(STDIN_FILENO, &buf, 3)
        guard n > 0 else { return nil }

        if n == 1 {
            switch buf[0] {
            case 0x0A, 0x0D: return .enter
            case 0x20: return .space
            case 0x1B: return .escape
            case 0x71: return .char("q")
            case 0x70: return .char("p")
            case 0x61: return .char("a")
            case 0x63: return .char("c")
            default:
                let scalar = Unicode.Scalar(buf[0])
                return .char(Character(scalar))
            }
        }

        if n == 3, buf[0] == 0x1B, buf[1] == 0x5B {
            switch buf[2] {
            case 0x41: return .up
            case 0x42: return .down
            case 0x43: return .right
            case 0x44: return .left
            default: return nil
            }
        }
        return nil
    }
}

class TerminalState {
    private var originalTermios: termios?
    private var isRaw = false

    static let shared = TerminalState()

    func enterRawMode() {
        guard !isRaw else { return }
        var raw = termios()
        tcgetattr(STDIN_FILENO, &raw)
        originalTermios = raw
        raw.c_lflag &= ~UInt(ECHO | ICANON | ISIG)
        raw.c_cc.16 = 1  // VMIN
        raw.c_cc.17 = 0  // VTIME
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        isRaw = true
        print(ANSICode.altScreenOn + ANSICode.hideCursor, terminator: "")
        fflush(stdout)

        signal(SIGINT) { _ in
            TerminalState.shared.exitRawMode()
            exit(0)
        }
    }

    func exitRawMode() {
        guard isRaw, var original = originalTermios else { return }
        isRaw = false
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
        print(ANSICode.showCursor + ANSICode.altScreenOff, terminator: "")
        fflush(stdout)
        signal(SIGINT, SIG_DFL)
    }
}

func isTTY() -> Bool {
    isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
}

/// Returns true if the user typed ONLY "music <command>" with no additional args or flags.
/// Checks CommandLine.arguments directly so default values can't fool it.
func isBareInvocation(command: String) -> Bool {
    let args = CommandLine.arguments.dropFirst() // drop binary path
    return args.count == 1 && args.first?.lowercased() == command.lowercased()
}
