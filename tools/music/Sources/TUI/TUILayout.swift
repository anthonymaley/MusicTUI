import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Screen Frame

struct ScreenFrame {
    let width: Int
    let height: Int
    let bodyY: Int
    let statusY: Int
    let footerY: Int

    static func current() -> ScreenFrame {
        var ws = winsize()
        _ = ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws)
        let w = Int(ws.ws_col) > 0 ? Int(ws.ws_col) : 120
        let h = Int(ws.ws_row) > 0 ? Int(ws.ws_row) : 30
        let footerY = h - 1
        let statusY = footerY - 1
        let bodyY = 7
        return ScreenFrame(width: w, height: h, bodyY: bodyY, statusY: statusY, footerY: footerY)
    }
}

// MARK: - Shared Shell Chrome

/// Renders the shared chrome: app label, title, accent rule, status, and footer.
/// Returns the ANSI string to print. Caller appends body content after this.
func renderShell(title: String, status: String, footer: String) -> String {
    let frame = ScreenFrame.current()
    let appX = 3

    var out = ANSICode.cursorHome

    // App label
    out += ANSICode.moveTo(row: 2, col: appX)
    out += ANSICode.clearLine
    out += "\(ANSICode.dim)music\(ANSICode.reset)"

    // Title
    out += ANSICode.moveTo(row: 4, col: appX)
    out += ANSICode.clearLine
    out += "\(ANSICode.bold)\(ANSICode.cyan)\u{266B} \(title)\(ANSICode.reset)"

    // Accent rule
    out += ANSICode.moveTo(row: 5, col: appX)
    out += ANSICode.clearLine
    out += "\(ANSICode.dim)\(String(repeating: "\u{2500}", count: min(40, title.count + 4)))\(ANSICode.reset)"

    // Status row
    out += ANSICode.moveTo(row: frame.statusY, col: appX)
    out += ANSICode.clearLine
    out += "\(ANSICode.green)\(status)\(ANSICode.reset)"

    // Footer
    out += ANSICode.moveTo(row: frame.footerY, col: appX)
    out += ANSICode.clearLine
    out += "\(ANSICode.dim)\(footer)\(ANSICode.reset)"

    return out
}

/// Clears the body region (rows between the title rule and the status line) so
/// a repaint never leaves stale characters from a previous, longer frame.
/// Uses clearLine (ESC[2K) rather than space-fill to stay friendly to
/// transparent terminals. Call right after `renderShell`, before drawing body
/// content.
func clearBody(_ frame: ScreenFrame) -> String {
    var out = ""
    for row in frame.bodyY..<frame.statusY {
        out += ANSICode.moveTo(row: row, col: 1)
        out += ANSICode.clearLine
    }
    return out
}

// MARK: - Text Helpers

/// Truncate text to a maximum width, adding ellipsis if needed.
func truncText(_ text: String, to maxWidth: Int) -> String {
    guard text.count > maxWidth, maxWidth > 1 else { return text }
    return String(text.prefix(maxWidth - 1)) + "\u{2026}"
}

/// Render a horizontal meter bar for volume/progress.
/// Returns a colored string of the given width.
func meterBar(value: Int, width: Int) -> String {
    let clamped = max(0, min(100, value))
    let filled = Int(Double(clamped) / 100.0 * Double(width))
    let empty = width - filled
    return "\(ANSICode.green)\(String(repeating: "\u{2588}", count: filled))\(ANSICode.reset)\(ANSICode.dim)\(String(repeating: "\u{2591}", count: empty))\(ANSICode.reset)"
}
