// Real cover art for the Library/Playlists hero panes. Album artwork URLs are
// stable {w}x{h} CDN templates; playlist artwork URLs are pre-signed and expire
// in 24h (both live-probed 2026-07-14) — so bytes are cached on disk forever,
// URLs never are. Rendering reuses artworkToAscii (chafa half-blocks, mono
// fallback). Every failure degrades silently to the caller's gradient
// placeholder; a per-session negative cache stops retry loops.
import Foundation

/// One cover's render result: half-block text lines (the chafa/mono fallback
/// ladder, unchanged) or a kitty-protocol placement descriptor. `transmit` is
/// non-nil exactly once per id per session (design doc sharp edge #3,
/// "Transmit once, place per frame-change") — callers place unconditionally
/// but only emit the transmit escape when it's non-nil.
enum ArtBlock {
    case lines([String])
    case kitty(id: UInt32, transmit: String?)
}

final class ArtworkStore {
    /// {w}x{h} substitution for album CDN templates; pre-signed playlist URLs
    /// contain no placeholder and pass through verbatim.
    static func resolveURL(_ template: String, width: Int, height: Int) -> String {
        template.replacingOccurrences(of: "{w}x{h}", with: "\(width)x\(height)")
    }

    /// Filesystem-safe cache key from a REST resource id.
    static func cacheKey(_ raw: String) -> String {
        String(raw.map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }

    private let cacheDir: String
    private let fetch: (String) -> Data?
    private let render: (String, Int, Int) -> [String]
    private let queue = DispatchQueue(label: "music.artwork")
    private let lock = NSLock()
    private var rendered: [String: [String]] = [:]   // "\(key)|\(w)x\(h)" → lines
    private var inFlight: Set<String> = []            // memoKey (lines) or "kitty|\(key)" (block)
    private var failed: Set<String> = []             // per-session negative cache (bytes OR PNG conversion)
    // Kitty path: the transmit escape is built once per key (PNG conversion is
    // the expensive part) and handed out exactly once — `transmitted` gates
    // every call after the first to `.kitty(id:, transmit: nil)` regardless of
    // whether `kittyEscape` still holds the string.
    private var kittyEscape: [String: String] = [:]  // key → cached transmit escape
    private var transmitted: Set<UInt32> = []         // ids already handed a non-nil transmit

    init(cacheDir: String = NSString(string: "~/.config/music/art-cache").expandingTildeInPath,
         fetch: ((String) -> Data?)? = nil,
         render: ((String, Int, Int) -> [String])? = nil) {
        self.cacheDir = cacheDir
        self.fetch = fetch ?? { urlString in
            guard let url = URL(string: urlString) else { return nil }
            return try? Data(contentsOf: url)   // store's serial queue only, never the main thread
        }
        self.render = render ?? { path, w, h in artworkToAscii(path: path, width: w, height: h) }
    }

    /// Ensure `key`'s raw artwork bytes are cached to disk (fetching once,
    /// never twice, on a miss) and return the local path. nil on a failed
    /// fetch — negative-cached in `failed` so neither caller loops retries for
    /// the session. Runs on `queue`; both the chafa/mono path (`lines`) and
    /// the kitty path (`block`) share this instead of duplicating the
    /// fetch-once/negative-cache flow.
    private func ensureBytesOnDisk(key: String, url: String) -> String? {
        let path = "\(cacheDir)/\(key)"
        if FileManager.default.fileExists(atPath: path) { return path }
        try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        guard let data = fetch(url), !data.isEmpty else {
            lock.lock(); failed.insert(key); lock.unlock()
            return nil
        }
        try? data.write(to: URL(fileURLWithPath: path))
        return path
    }

    /// Rendered cover lines if ready, else nil — and (once per key+size) a
    /// background fetch+render is kicked; `onReady` fires from the store's queue
    /// when lines land. Callers repaint on their next tick and get the memory hit.
    func lines(key rawKey: String, url: String, width: Int, height: Int,
               onReady: @escaping () -> Void) -> [String]? {
        let key = Self.cacheKey(rawKey)
        let memoKey = "\(key)|\(width)x\(height)"
        lock.lock()
        if let hit = rendered[memoKey] { lock.unlock(); return hit }
        if failed.contains(key) || inFlight.contains(memoKey) { lock.unlock(); return nil }
        inFlight.insert(memoKey)
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            guard let path = self.ensureBytesOnDisk(key: key, url: url) else {
                self.lock.lock(); self.inFlight.remove(memoKey); self.lock.unlock()
                return
            }
            let lines = self.render(path, width, height)
            self.lock.lock()
            if lines.isEmpty { self.failed.insert(key) } else { self.rendered[memoKey] = lines }
            self.inFlight.remove(memoKey)
            self.lock.unlock()
            if !lines.isEmpty { onReady() }
        }
        return nil
    }

    /// Same fetch/cache contract as `lines()`, but for the kitty graphics
    /// protocol: `kitty: false` is exactly today's `lines()` flow wrapped in
    /// `.lines`. `kitty: true` ensures bytes are on disk, converts them to PNG
    /// off the main thread (the protocol's direct-transmit format is PNG-only;
    /// cached bytes are JPEG — design doc sharp edge #2), and returns a stable
    /// id + the transmit escape the FIRST time only — `nil` transmit on every
    /// call after (sharp edge #3: "Transmit once, place per frame-change").
    /// PNG conversion failure is treated like a render failure: negative-cached
    /// in `failed`, same as a fetch failure. While bytes/PNG aren't ready yet,
    /// returns nil and fires `onReady` later, same as `lines()`.
    func block(key rawKey: String, url: String, width: Int, height: Int,
               kitty: Bool, onReady: @escaping () -> Void) -> ArtBlock? {
        guard kitty else {
            return lines(key: rawKey, url: url, width: width, height: height, onReady: onReady).map { .lines($0) }
        }
        let key = Self.cacheKey(rawKey)
        let id = kittyImageID(forKey: key)
        let inFlightKey = "kitty|\(key)"

        lock.lock()
        if transmitted.contains(id) { lock.unlock(); return .kitty(id: id, transmit: nil) }
        if let escape = kittyEscape[key] {
            transmitted.insert(id)
            lock.unlock()
            return .kitty(id: id, transmit: escape)
        }
        if failed.contains(key) || inFlight.contains(inFlightKey) { lock.unlock(); return nil }
        inFlight.insert(inFlightKey)
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            guard let path = self.ensureBytesOnDisk(key: key, url: url),
                  let data = FileManager.default.contents(atPath: path),
                  let png = imageDataToPNG(data) else {
                self.lock.lock(); self.failed.insert(key); self.inFlight.remove(inFlightKey); self.lock.unlock()
                return
            }
            let escape = kittyTransmitEscape(id: id, png: png)
            self.lock.lock()
            self.kittyEscape[key] = escape
            self.inFlight.remove(inFlightKey)
            self.lock.unlock()
            onReady()
        }
        return nil
    }
}

/// One scene's kitty placement-dedup state: the last placement it emitted, so
/// an unchanged frame emits nothing (the placement persists on screen across
/// text repaints) and a changed one deletes the old placement before drawing
/// the new one. Each art-rendering scene keeps exactly one, reset to nil in
/// `artPlacementsInvalidated()`.
typealias ArtPlacement = (id: UInt32, row: Int, col: Int, cols: Int, rows: Int)

/// Render one hero art block — kitty placement, chafa/mono lines, or the
/// gradient identicon fallback — into `out` at column `x` starting at row
/// `startY`. Shared by every hero pane (LibraryScene, PlaylistsScene, and now
/// RadioScene each need this exact ladder) so the kitty aspect-clamp lives in
/// one place instead of being copy-pasted per scene: kitty placement
/// STRETCHES to the cell rect while chafa letterboxes, so the rect is clamped
/// to square-equivalent (cols = 2×rows at ~1:2 cell aspect) or a narrow hero
/// stretches art tall (docs/playbook.md Gotchas).
///
/// `lastPlaced` is the caller's own placement-dedup state; this returns the
/// row past the rendered art plus the new placement value for the caller to
/// store. `gradientSeedText` seeds the deterministic gradient fallback and
/// its tint. Nothing here ever throws or errors at the user — art is
/// decoration, and `.none` always degrades to the gradient block.
func renderArtHero(artBlock: ArtBlock?, gradientSeedText: String,
                   gw: Int, gh: Int, x: Int, y startY: Int,
                   lastPlaced: ArtPlacement?,
                   into out: inout String) -> (y: Int, lastPlaced: ArtPlacement?) {
    var y = startY
    var placed = lastPlaced
    switch artBlock {
    case .lines(let art):
        if let last = placed { out += kittyDeleteEscape(id: last.id); placed = nil }
        // Pad/cap to exactly gh rows so the hero's height never shifts and
        // stale gradient rows are overwritten (chafa may emit fewer rows).
        let blank = String(repeating: " ", count: gw)
        let rows = art.prefix(gh) + Array(repeating: blank, count: max(0, gh - art.count))
        for line in rows {
            out += ANSICode.moveTo(row: y, col: x) + line + ANSICode.reset
            y += 1
        }
    case .kitty(let id, let transmit):
        let pr = min(gh, gw / 2)
        let pc = min(gw, pr * 2)
        let current: ArtPlacement = (id: id, row: y, col: x, cols: pc, rows: pr)
        if let last = placed, last == current {
            // Unchanged: the placement from a prior frame is still on
            // screen — emit nothing (spaces would flicker under the image).
        } else {
            if let last = placed { out += kittyDeleteEscape(id: last.id) }
            let blank = String(repeating: " ", count: gw)
            for i in 0..<gh {
                out += ANSICode.moveTo(row: y + i, col: x) + blank
            }
            out += transmit ?? ""
            out += ANSICode.moveTo(row: y, col: x) + kittyPlaceEscape(id: id, cols: pc, rows: pr)
            placed = current
        }
        y += gh
    case .none:
        if let last = placed { out += kittyDeleteEscape(id: last.id); placed = nil }
        let gradient = gradientBlock(name: gradientSeedText, width: gw, height: gh)
        var seed = 0; for b in gradientSeedText.unicodeScalars { seed = (seed &* 31 &+ Int(b.value)) & 0xffffff }
        let r = 80 + (seed & 0x7f), g = 80 + ((seed >> 8) & 0x7f), bl = 80 + ((seed >> 16) & 0x7f)
        let color = "\u{1B}[38;2;\(r);\(g);\(bl)m"
        for line in gradient {
            out += ANSICode.moveTo(row: y, col: x) + "\(color)\(line)\(ANSICode.reset)"
            y += 1
        }
    }
    return (y, placed)
}
