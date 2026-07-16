// tools/music/Sources/TUI/KittyGraphics.swift
// Pure encoder for the kitty graphics protocol (spec:
// https://sw.kovidgoyal.net/kitty/graphics-protocol/). No terminal I/O here —
// these functions build escape strings and convert bytes; callers write the
// result to stdout. See docs/plans/2026-07-14-vim-keys-and-kitty-art-design.md
// Feature 2 "Sharp edges" for the constraints this file must honor.
import Foundation
import CoreGraphics
import ImageIO

/// Terminal supports the kitty graphics protocol? Env-based detection (v1,
/// no stdin response parsing — see design doc sharp edge #5). Apple_Terminal
/// and anything unrecognized falls through to false (chafa/mono/gradient).
func kittyGraphicsSupported(env: [String: String]) -> Bool {
    if env["KITTY_WINDOW_ID"] != nil { return true }
    if let term = env["TERM"], term.contains("kitty") { return true }
    let termProgram = env["TERM_PROGRAM"]
    if termProgram == "WezTerm" || termProgram == "ghostty" { return true }
    if termProgram == "iTerm.app", let version = env["TERM_PROGRAM_VERSION"] {
        return iTermVersionAtLeast(version, major: 3, minor: 5)
    }
    return false
}

/// "3.5.9" / "3.4" / garbage -> major.minor comparison, missing components
/// treated as 0. Not a tuple `>=` (stdlib only synthesizes `<`/`==` for
/// tuples) — spelled out explicitly instead.
private func iTermVersionAtLeast(_ version: String, major: Int, minor: Int) -> Bool {
    let parts = version.split(separator: ".")
    let gotMajor = parts.count > 0 ? Int(parts[0]) ?? 0 : 0
    let gotMinor = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
    if gotMajor != major { return gotMajor > major }
    return gotMinor >= minor
}

/// Stable nonzero image id for an artwork cache key. FNV-1a 32-bit over the
/// UTF-8 bytes; the protocol reserves id 0, so a 0 result is bumped to 1
/// (design doc sharp edge #3). Appropriate when `key` already uniquely and
/// stably identifies the image content (e.g. ArtworkStore's on-disk cache
/// keys, which are never overwritten with different content) — see
/// `kittyImageID(forBytes:)` for the case where the caller can't guarantee
/// that and needs the id to reflect the actual bytes instead.
func kittyImageID(forKey key: String) -> UInt32 {
    kittyImageID(forBytes: Data(key.utf8))
}

/// Stable nonzero image id for raw image bytes — same FNV-1a algorithm as
/// `kittyImageID(forKey:)`, over the content directly rather than a
/// caller-supplied label. Use this whenever the label (a path, a track name)
/// could go stale relative to what's actually in the file; the id then
/// reflects reality instead of trusting the label (see
/// NowPlayingScene.kittyIdentity(forPath:) for the bug this fixed — a poller
/// temp path whose bytes could change without the label changing).
func kittyImageID(forBytes data: Data) -> UInt32 {
    var hash: UInt32 = 0x811c_9dc5          // FNV offset basis
    for byte in data {
        hash ^= UInt32(byte)
        hash = hash &* 0x0100_0193          // FNV prime
    }
    return hash == 0 ? 1 : hash
}

/// JPEG (or any CGImageSource-readable) bytes -> PNG bytes. The protocol's
/// direct-transmit format is PNG-only (`f=100`); our cached artwork bytes are
/// JPEG off the mzstatic CDN (design doc sharp edge #2). nil on failure —
/// callers fall back to the chafa/mono/gradient ladder.
func imageDataToPNG(_ data: Data) -> Data? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
        return nil
    }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return output as Data
}

private let kittyChunkSize = 4096   // max base64 bytes per escape payload (spec: "no larger than 4096")

/// Transmit-only escape(s) for a PNG, chunked at 4096 base64 bytes per the
/// spec's remote-client chunking rules; `q=2` (suppress both OK and error
/// replies) on every chunk so the terminal never writes a reply onto stdin,
/// which our raw-mode key loop would otherwise read as garbage keypresses
/// (design doc sharp edge #1). Action is `a=t` — transmit data only, no
/// display; placement is a separate `a=p` escape (sharp edge #3). Only the
/// first chunk carries the full control set (`a`, `f`, `i`, `q`); subsequent
/// chunks carry only `m` and `q`, per spec: "Subsequent chunks must have only
/// the m and optionally q keys."
func kittyTransmitEscape(id: UInt32, png: Data) -> String {
    let base64 = png.base64EncodedString()
    var chunks: [Substring] = []
    var idx = base64.startIndex
    repeat {
        let end = base64.index(idx, offsetBy: kittyChunkSize, limitedBy: base64.endIndex) ?? base64.endIndex
        chunks.append(base64[idx..<end])
        idx = end
    } while idx < base64.endIndex

    var result = ""
    for (offset, chunk) in chunks.enumerated() {
        let isFirst = offset == 0
        let isLast = offset == chunks.count - 1
        var controls: [String] = []
        if isFirst {
            controls += ["a=t", "f=100", "i=\(id)"]
        }
        controls += ["q=2", "m=\(isLast ? 0 : 1)"]
        result += "\u{1B}_G\(controls.joined(separator: ","));\(chunk)\u{1B}\\"
    }
    return result
}

/// Place image id at the cursor, scaled to cols x rows cells. Measured
/// against a real terminal: the terminal STRETCHES the image to fill that
/// cell rect — it does NOT preserve aspect ratio (unlike the chafa/mono
/// fallback, which letterboxes). Callers must pick cols/rows that are already
/// square-equivalent for the terminal's measured cell size — see
/// `kittySquareRect` below — rather than assuming a fixed cell aspect.
/// `q=2` per sharp edge #1.
func kittyPlaceEscape(id: UInt32, cols: Int, rows: Int) -> String {
    "\u{1B}_Ga=p,i=\(id),c=\(cols),r=\(rows),q=2\u{1B}\\"
}

/// A placement rect (cols x rows), never larger than `maxCols` x `maxRows`,
/// that renders SQUARE in pixels for the given measured terminal cell size.
/// `kittyPlaceEscape` stretches an image to whatever cell rect it's given, so
/// a square cover needs cols/rows whose pixel dimensions (cols*cellW vs.
/// rows*cellH) actually come out square — not a fixed cols=2*rows guess
/// (measured wrong on a real terminal: 14x34px cells, ratio 1:2.429, not
/// 1:2 — docs/playbook.md).
///
/// Widens to `maxCols` first (matches the shape of the old cols=2*rows
/// behavior when cellW:cellH is close to 1:2), then falls back to
/// constraining by `maxRows` when that would be too tall for the space
/// available. Degrades to (0, 0) on invalid input — callers already gate on
/// gw/gh > 0 before reaching the kitty path, so this is a defensive floor,
/// not the primary guard. Pure, so it's unit-testable without a terminal.
func kittySquareRect(maxCols: Int, maxRows: Int, cellW: Double, cellH: Double) -> (cols: Int, rows: Int) {
    guard maxCols > 0, maxRows > 0, cellW > 0, cellH > 0 else { return (0, 0) }
    var pc = maxCols
    var pr = Int((Double(pc) * cellW / cellH).rounded())
    if pr > maxRows {
        pr = maxRows
        pc = Int((Double(pr) * cellH / cellW).rounded())
    }
    pc = max(1, min(maxCols, pc))
    pr = max(1, min(maxRows, pr))
    return (pc, pr)
}

/// Delete all placements of one image id, keeping the stored image data
/// (`d=i`, lowercase — the spec: "The lowercase variant only deletes the
/// images without necessarily freeing up the stored image data, so that the
/// images can be re-displayed without needing to resend the data"). Scenes
/// call this when the displayed cover changes, since a cleared text frame
/// does NOT clear placed images (design doc sharp edge #4); re-placing the
/// same id later needs no re-transmit.
func kittyDeleteEscape(id: UInt32) -> String {
    "\u{1B}_Ga=d,d=i,i=\(id),q=2\u{1B}\\"
}

/// Delete every image and placement, freeing all stored data (`d=A`,
/// uppercase — frees data per the spec's lower/uppercase distinction). Used
/// once, on TUI exit, alongside the shell's existing terminal restore, so no
/// image ghosts survive into scrollback.
func kittyDeleteAllEscape() -> String {
    "\u{1B}_Ga=d,d=A,q=2\u{1B}\\"
}

/// Delete ALL placements but keep transmitted data (`d=a`, lowercase and
/// unscoped by id — the spec's lowercase variants never free stored image
/// data). Used on scene switches: the shell prints this once, then every art
/// scene resets its placement-dedup state (`artPlacementsInvalidated()`), so
/// the incoming scene re-places its cover without re-transmitting bytes the
/// terminal already has.
func kittyDeletePlacementsEscape() -> String {
    "\u{1B}_Ga=d,d=a,q=2\u{1B}\\"
}
