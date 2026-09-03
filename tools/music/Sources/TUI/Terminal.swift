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
    static let red = "\u{1B}[31m"
    static let green = "\u{1B}[32m"
    static let cyan = "\u{1B}[36m"
    static let yellow = "\u{1B}[33m"
    static let brightWhite = "\u{1B}[97m"
    static let lime = "\u{1B}[92m"
    static let amber = "\u{1B}[38;2;255;176;0m"
    static let white = "\u{1B}[37m"

    static func moveTo(row: Int, col: Int) -> String {
        "\u{1B}[\(row);\(col)H"
    }
}

enum KeyPress: Equatable {
    case up, down, left, right
    case pageUp, pageDown, home, end
    case shiftTab
    case f7, f9
    case enter, space, escape
    /// A typed Ctrl-C. Raw mode clears `ISIG`, so the terminal delivers it as
    /// byte `0x03` rather than a signal; named here so the shell can route it
    /// to quit ahead of every scene, including the ones capturing raw text.
    /// An externally delivered SIGINT is a different path (the handler in
    /// `enterRawMode`) and is unchanged by this.
    case ctrlC
    case char(Character)

    /// How long to wait for a follow-up byte after a bare ESC (0x1B) before
    /// concluding it WAS a standalone Escape keypress rather than the start of
    /// a CSI/SS3 escape sequence. Terminals emit an escape sequence as a
    /// single burst — intra-sequence byte gaps are ~0 even over SSH — so 25ms
    /// is far above any real sequence gap and far below human perception, so
    /// it never misreads a genuine sequence as a bare Esc.
    private static let escDisambiguationMs: Int32 = 25

    /// Byte source seam. Production reads stdin directly (raw mode, see
    /// `.stdin` below); tests substitute a scripted queue so ESC-disambiguation
    /// timeouts can be simulated without a real clock.
    struct ByteInput {
        var next: () -> UInt8?             // blocking read (waits indefinitely)
        var nextWithin: (Int32) -> UInt8?  // poll(ms) then read; nil on timeout

        static let stdin = ByteInput(
            next: {
                var byte: UInt8 = 0
                guard Darwin.read(STDIN_FILENO, &byte, 1) == 1 else { return nil }
                return byte
            },
            nextWithin: { ms in
                var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, ms)
                guard ready > 0, pfd.revents & Int16(POLLIN) != 0 else { return nil }
                var byte: UInt8 = 0
                guard Darwin.read(STDIN_FILENO, &byte, 1) == 1 else { return nil }
                return byte
            }
        )
    }

    /// Production default; tests overwrite this with a scripted `ByteInput`.
    static var input: ByteInput = .stdin

    /// One-byte requeue: when ESC-disambiguation reads a byte that turns out
    /// to belong to the NEXT keypress (not this escape sequence), it is
    /// stashed here and handed back on the following read. Keys are only
    /// ever read from the single UI loop thread (Shell.swift's read loop,
    /// VolumeMixer.swift, MultiSelectList.swift all read serially, one key
    /// at a time, from one thread) — so this needs no lock.
    private static var pushback: UInt8?

    /// Next byte, blocking indefinitely. Drains `pushback` first if set.
    private static func nextByte() -> UInt8? {
        if let b = pushback { pushback = nil; return b }
        return input.next()
    }

    /// Next byte within `ms`, nil on timeout. Drains `pushback` first if set
    /// (a pending pushback is always "immediately available").
    private static func nextByte(within ms: Int32) -> UInt8? {
        if let b = pushback { pushback = nil; return b }
        return input.nextWithin(ms)
    }

    /// Test hook: reset the byte-source seam and any pending pushback byte.
    /// Not `private` so `@testable import` tests can call it from
    /// setUp/tearDown; production code never calls this.
    static func resetInputForTesting() {
        input = .stdin
        pushback = nil
    }

    /// Parse a single keypress given its already-read first byte.
    private static func parseKey(firstByte byte: UInt8) -> KeyPress? {
        if byte == 0x1B {
            // ESC received — wait briefly for a follow-up byte to disambiguate
            // a bare Esc keypress from the start of a CSI/SS3 sequence. Every
            // read from here on uses the same short timeout: real terminals
            // never split one escape sequence across a 25ms gap, so a timeout
            // anywhere in this path means the sequence is over (or was never
            // more than a bare Esc).
            guard let seq1 = nextByte(within: escDisambiguationMs) else { return .escape }
            if seq1 == 0x5B {
                guard let seq2 = nextByte(within: escDisambiguationMs) else { return .escape }
                switch seq2 {
                case 0x41: return .up
                case 0x42: return .down
                case 0x43: return .right
                case 0x44: return .left
                case 0x48: return .home      // ESC [ H
                case 0x46: return .end       // ESC [ F
                case 0x5A: return .shiftTab  // ESC [ Z
                case 0x31...0x39:
                    var sequence = String(UnicodeScalar(seq2))
                    var bytesRead = 0
                    while bytesRead < 8, let next = nextByte(within: escDisambiguationMs) {
                        bytesRead += 1
                        sequence.append(Character(UnicodeScalar(next)))
                        if next == 0x7E || (next >= 0x40 && next <= 0x7E) {
                            break
                        }
                    }
                    switch sequence {
                    case "5~": return .pageUp
                    case "6~": return .pageDown
                    case "1~", "7~": return .home
                    case "4~", "8~": return .end
                    case "18~": return .f7
                    case "20~": return .f9
                    default: return nil
                    }
                default: return nil
                }
            }
            if seq1 == 0x4F {
                // Application-mode Home/End (ESC O H / ESC O F).
                guard let seq2 = nextByte(within: escDisambiguationMs) else { return .escape }
                switch seq2 {
                case 0x48: return .home
                case 0x46: return .end
                default: return nil
                }
            }
            // seq1 is neither '[' nor 'O' — it belongs to the NEXT keypress,
            // not this escape sequence. Requeue it and report a bare Escape
            // for THIS call; the requeued byte is returned on the next read.
            pushback = seq1
            return .escape
        }

        switch byte {
        case 0x03: return .ctrlC
        case 0x0A, 0x0D: return .enter
        case 0x20: return .space
        default:
            return .char(Character(Unicode.Scalar(byte)))
        }
    }

    /// Blocking read — waits indefinitely for a keypress.
    static func read() -> KeyPress? {
        guard let byte = nextByte() else { return nil }
        return parseKey(firstByte: byte)
    }

    /// Read with timeout in seconds. Returns nil if no key pressed within timeout.
    static func read(timeout: Double) -> KeyPress? {
        let ms = Int32(timeout * 1000)
        guard let byte = nextByte(within: ms) else { return nil }
        return parseKey(firstByte: byte)
    }
}

/// Global flag set by SIGWINCH handler — check and reset in render loops.
var terminalResized = false

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
        withUnsafeMutablePointer(to: &raw.c_cc) { ptr in
            let base = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: cc_t.self)
            base[Int(VMIN)] = 1
            base[Int(VTIME)] = 0
        }
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        isRaw = true
        print(ANSICode.altScreenOn + ANSICode.hideCursor, terminator: "")
        fflush(stdout)

        signal(SIGINT) { _ in
            TerminalState.shared.exitRawMode()
            exit(0)
        }
        signal(SIGWINCH) { _ in
            terminalResized = true
        }
    }

    func exitRawMode() {
        guard isRaw, var original = originalTermios else { return }
        isRaw = false
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
        print(ANSICode.showCursor + ANSICode.altScreenOff, terminator: "")
        fflush(stdout)
        signal(SIGINT, SIG_DFL)
        signal(SIGWINCH, SIG_DFL)
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
