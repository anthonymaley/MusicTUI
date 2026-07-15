// tools/music/Sources/TUI/Shell/PlaylistsScene.swift
import Foundation

final class PlaylistsScene: Scene {
    let id: SceneID = .playlists
    let tabTitle = "Playlists"
    var capturesAllInput: Bool { filtering }
    var footerHint: String {
        if filtering { return "type to filter  Enter Apply  Esc Clear" }
        return focus == .tracks
            ? "\u{2191}\u{2193} Track  Enter Play  \u{2190} Back"
            : "\u{2191}\u{2193} Move  Enter Open  p Play  s Shuffle  / Filter"
    }

    private let backend: AppleScriptBackend
    private let playlists: [String]
    private let subscriptionNames: Set<String>
    private let sources: PlaylistDataSources
    private let appQueue: AppQueueStore
    private let status: StatusStore
    private let actions: ActionRunner

    private var focus: BrowserFocus = .playlists
    private var plCursor = 0
    private var plScroll = 0
    private var trCursor = 0
    private var trScroll = 0
    private var meta: [PlaylistMeta]
    private var loaded: Set<Int> = []
    private var fullCache: [Int: PlaylistPreview] = [:]
    private var previewLines: [Int: [String]] = [:]
    private var filterText = ""
    private var filtering = false

    // Off-thread metadata refresh: a background thread fetches via `onMeta` and posts
    // results to `inbox`; tick() drains them on the main thread, so `meta` stays
    // main-thread-only and the slow AppleScript never blocks a render frame.
    private let inboxLock = NSLock()
    private var inbox: [Int: (Int, Int, Bool, String)] = [:]

    // Preview fetches follow the same inbox pattern (an inline fetch in tick()
    // froze input for one osascript round-trip per uncached rail row). A serial
    // queue both keeps `onPreview`'s internal cache single-threaded and avoids
    // piling concurrent AppleScript load onto Music while scrolling.
    private let previewQueue = DispatchQueue(label: "music.playlists.preview")
    private let previewInboxLock = NSLock()
    private var previewInbox: [Int: [String]] = [:]
    private var previewInFlight: Set<Int> = []   // tick()-thread only

    // Full track lists land the same way (Enter kicks the fetch, tick drains).
    private var fullInbox: [Int: PlaylistPreview] = [:]   // guarded by previewInboxLock
    private var fullInFlight: Set<Int> = []               // tick()/handle()-thread only

    // Real hero covers. artMap lands once from a background REST walk (inbox
    // discipline: posted under inboxLock, drained in tick); ArtworkStore then
    // owns per-cover fetch/cache/render. No token → onArtworkMap is nil and
    // gradients stay.
    private let artwork = ArtworkStore()
    private var artMap: [String: (id: String, url: String)] = [:]
    private var artMapInbox: [String: (id: String, url: String)]? = nil
    private var artMapStarted = false
    private var artDirty = false

    private let metaCol = 6

    init(backend: AppleScriptBackend, playlists: [String], subscriptionNames: Set<String> = [],
         sources: PlaylistDataSources,
         appQueue: AppQueueStore, status: StatusStore, actions: ActionRunner) {
        self.backend = backend
        self.playlists = playlists
        self.subscriptionNames = subscriptionNames
        self.sources = sources
        self.appQueue = appQueue
        self.status = status
        self.actions = actions
        self.meta = playlists.map { PlaylistMeta(name: $0) }
        // Seed the rail from the on-disk cache so it paints fully on first frame;
        // a background pass then refreshes every playlist and rewrites the cache.
        let cache = PlaylistMetaCache.load()
        for i in 0..<meta.count {
            guard let c = cache[meta[i].name] else { continue }
            meta[i].trackCount = c.count
            meta[i].durationSec = c.durationSec
            meta[i].isSmart = c.isSmart
            meta[i].specialKind = c.specialKind
            meta[i].loaded = true
            loaded.insert(i)
        }
        startBackgroundRefresh()
    }

    /// Refresh every playlist's metadata off the main thread (so render never
    /// blocks on AppleScript), posting results to `inbox` and rewriting the cache.
    /// Batches can fail transiently when Music is under concurrent AppleScript load
    /// at startup (poller + preview fetches), so any index that doesn't come back is
    /// retried with backoff until all resolve or the attempt cap is hit.
    private func startBackgroundRefresh() {
        let names = playlists
        let sources = self.sources
        Thread.detachNewThread { [weak self] in
            var merged = PlaylistMetaCache.load()
            var pending = Set(0..<names.count)
            var attempt = 0
            while !pending.isEmpty && attempt < 5 {
                attempt += 1
                let todo = pending.sorted()
                var i = 0
                while i < todo.count {
                    let batch = Array(todo[i..<min(i + 8, todo.count)])
                    let fetched = sources.onMeta(batch)
                    if !fetched.isEmpty { self?.postMeta(fetched) }
                    for (idx, v) in fetched where idx >= 0 && idx < names.count {
                        merged[names[idx]] = CachedPlaylistMeta(count: v.0, durationSec: v.1, isSmart: v.2, specialKind: v.3)
                        pending.remove(idx)
                    }
                    i += 8
                }
                if !pending.isEmpty { Thread.sleep(forTimeInterval: 0.6) } // let Music settle, then retry
            }
            PlaylistMetaCache.save(merged)
        }
    }

    private func postMeta(_ results: [Int: (Int, Int, Bool, String)]) {
        inboxLock.lock(); for (k, v) in results { inbox[k] = v }; inboxLock.unlock()
    }

    private func drainMeta() -> [Int: (Int, Int, Bool, String)] {
        inboxLock.lock(); defer { inboxLock.unlock() }
        let r = inbox; inbox = [:]; return r
    }

    // MARK: filter helpers

    /// Move the rail cursor by `delta` positions within the (possibly filtered)
    /// visible list, clamped to its ends.
    private func moveRail(by delta: Int) {
        let vis = visibleIndices()
        guard !vis.isEmpty else { return }
        let pos = vis.firstIndex(of: plCursor) ?? 0
        plCursor = vis[max(0, min(vis.count - 1, pos + delta))]
    }

    private func visibleIndices() -> [Int] {
        guard !filterText.isEmpty else { return Array(0..<meta.count) }
        let q = filterText.lowercased()
        return (0..<meta.count).filter { meta[$0].name.lowercased().contains(q) }
    }
    private func clampCursorToFilter() {
        let vis = visibleIndices()
        if !vis.contains(plCursor) { plCursor = vis.first ?? 0 }
        plScroll = 0
    }
    /// Kick the full track-list fetch off-thread (inbox pattern); the tracks
    /// pane shows "Loading…" until it lands. The old synchronous version froze
    /// the whole shell for the duration of a 200-track fetch on Enter.
    private func loadFull() {
        trCursor = 0; trScroll = 0
        guard fullCache[plCursor] == nil, !fullInFlight.contains(plCursor) else { return }
        fullInFlight.insert(plCursor)
        let idx = plCursor
        let name = playlists[plCursor]
        let sources = self.sources
        let status = self.status
        previewQueue.async { [weak self] in
            let preview = sources.onTracks(idx)
            if preview == nil { status.post("Couldn't load tracks for '\(name)'.", error: true) }
            guard let self else { return }
            self.previewInboxLock.lock()
            self.fullInbox[idx] = preview ?? PlaylistPreview(name: name, trackCount: 0, tracks: [])
            self.previewInboxLock.unlock()
        }
    }
    private func badgeText(_ m: PlaylistMeta) -> (String, String)? {
        switch playlistBadge(name: m.name, isSmart: m.isSmart ?? false, specialKind: m.specialKind ?? "none",
                             isSubscription: subscriptionNames.contains(m.name)) {
        case .radio: return ("RADIO", ANSICode.amber)
        case .smart: return ("SMART", ANSICode.amber)
        case .recent: return ("RECENT", ANSICode.amber)
        case .apple: return ("APPLE", ANSICode.amber)
        case .none: return nil
        }
    }

    // MARK: Scene

    @discardableResult
    func tick(snapshot: NowPlayingSnapshot) -> Bool {
        var changed = false
        if !artMapStarted, let load = sources.onArtworkMap {
            artMapStarted = true
            Thread.detachNewThread { [weak self] in
                let map = load()
                guard let self else { return }
                self.inboxLock.lock(); self.artMapInbox = map; self.inboxLock.unlock()
            }
        }
        // Apply metadata the background refresh thread has fetched (off-main), so
        // the slow AppleScript never blocks a render frame.
        let fresh = drainMeta()
        inboxLock.lock()
        let landedMap = artMapInbox; artMapInbox = nil
        let artLanded = artDirty; artDirty = false
        inboxLock.unlock()
        for (idx, v) in fresh where idx >= 0 && idx < meta.count {
            meta[idx].trackCount = v.0
            meta[idx].durationSec = v.1
            meta[idx].isSmart = v.2
            meta[idx].specialKind = v.3
            meta[idx].loaded = true
            loaded.insert(idx)
            changed = true
        }
        if let m = landedMap { artMap = m; changed = true }
        if artLanded { changed = true }
        // Landed preview and full-track fetches.
        previewInboxLock.lock()
        let freshPreviews = previewInbox; previewInbox = [:]
        let freshFull = fullInbox; fullInbox = [:]
        previewInboxLock.unlock()
        for (idx, lines) in freshPreviews {
            previewLines[idx] = lines
            previewInFlight.remove(idx)
            changed = true
        }
        for (idx, preview) in freshFull {
            fullCache[idx] = preview
            fullInFlight.remove(idx)
            changed = true
        }
        // Kick off a preview fetch (off-thread) when the pane is shown and empty.
        let z = playlistZones(width: ScreenFrame.current().width)
        if focus == .playlists, z.mode == .three,
           previewLines[plCursor] == nil, !previewInFlight.contains(plCursor) {
            previewInFlight.insert(plCursor)
            let idx = plCursor
            let sources = self.sources
            previewQueue.async { [weak self] in
                let lines = sources.onPreview(idx) ?? []
                guard let self else { return }
                self.previewInboxLock.lock()
                self.previewInbox[idx] = lines
                self.previewInboxLock.unlock()
            }
        }
        return changed
    }

    func render(frame: ShellFrame, snapshot: NowPlayingSnapshot) -> String {
        var out = ""
        // Clear the body region first.
        for r in frame.bodyY..<(frame.bodyY + frame.bodyHeight) {
            out += ANSICode.moveTo(row: r, col: 1) + ANSICode.clearLine
        }
        let z = playlistZones(width: frame.width)
        let bodyTop = frame.bodyY
        let bodyBottom = frame.bodyY + frame.bodyHeight - 1

        renderRail(z, into: &out, bodyTop: bodyTop, bodyBottom: bodyBottom)
        renderHero(z, into: &out, bodyTop: bodyTop, bodyBottom: bodyBottom)
        if focus == .tracks {
            renderTrackList(z, into: &out, bodyTop: bodyTop, bodyBottom: bodyBottom)
        } else {
            renderPreview(z, into: &out, bodyTop: bodyTop, bodyBottom: bodyBottom)
        }
        if filtering || !filterText.isEmpty {
            out += ANSICode.moveTo(row: bodyTop, col: z.railX)
            out += "\(ANSICode.cyan)/\(ANSICode.reset) \(ANSICode.brightWhite)\(filterText)\(ANSICode.reset)\(filtering ? "\u{2588}" : "")"
        }
        return out
    }

    func handle(_ key: KeyPress) -> SceneAction {
        let trackCount = fullCache[plCursor]?.tracks.count ?? 0

        if filtering {
            switch key {
            case .enter: filtering = false
            case .escape: filtering = false; filterText = ""; clampCursorToFilter()
            // Arrows navigate the filtered list WHILE typing (fzf-style) —
            // having to Enter out of filter mode first was pure friction.
            case .up: moveRail(by: -1)
            case .down: moveRail(by: 1)
            case .char(let c) where c == "\u{7F}" || c == "\u{8}":
                if !filterText.isEmpty { filterText.removeLast() }
                clampCursorToFilter()
            case .char(let c): filterText.append(c); clampCursorToFilter()
            default: break
            }
            return .redraw
        }

        switch key {
        case .up:
            if focus == .playlists { moveRail(by: -1) }
            else { trCursor = max(0, trCursor - 1) }
            return .redraw
        case .down:
            if focus == .playlists { moveRail(by: 1) }
            else { trCursor = min(max(0, trackCount - 1), trCursor + 1) }
            return .redraw
        case .pageUp:
            if focus == .playlists { moveRail(by: -10) }
            else { trCursor = max(0, trCursor - 10) }
            return .redraw
        case .pageDown:
            if focus == .playlists { moveRail(by: 10) }
            else { trCursor = min(max(0, trackCount - 1), trCursor + 10) }
            return .redraw
        case .home:
            if focus == .playlists, let first = visibleIndices().first { plCursor = first }
            else { trCursor = 0 }
            return .redraw
        case .end:
            if focus == .playlists, let last = visibleIndices().last { plCursor = last }
            else { trCursor = max(0, trackCount - 1) }
            return .redraw
        case .char("/"):
            filtering = true
            return .redraw
        case .enter:
            if focus == .playlists {
                loadFull(); focus = .tracks; trCursor = 0; trScroll = 0
                return .redraw
            } else {
                guard fullCache[plCursor] != nil else { return .none }   // still loading
                playTrack(trCursor)
                return .push(.nowPlaying)
            }
        case .left:
            if focus == .tracks { focus = .playlists; return .redraw }
            return .pop
        case .escape:
            if focus == .tracks { focus = .playlists; return .redraw }
            return .pop
        case .char("p"):
            playPlaylist(shuffle: false); return .push(.nowPlaying)
        case .char("s"):
            playPlaylist(shuffle: true); return .push(.nowPlaying)
        case .char("b"):
            return .push(.nowPlaying)
        default:
            return .none
        }
    }

    // MARK: playback (user-initiated; brief inline stall acceptable)

    private func playTrack(_ trackIndex: Int) {
        // App-owned queue (see AppQueue.swift). macOS 26.x broke `play track N of
        // playlist X`, so instead of leaning on Music's queue we hold the playlist
        // ourselves: fetch its tracks, register the queue at position N, and play
        // that one track. The poller advances when it stops at end (Music Autoplay
        // must be off), and next/prev/Enter navigate our list — full up/down. On the
        // action queue so the bulk track fetch never freezes the UI and failures
        // surface as a toast instead of a silent dead Enter.
        let name = playlists[plCursor]
        let pos = trackIndex + 1
        let store = self.appQueue
        let backend = self.backend
        actions.run("Play") {
            let tracks = fetchPlaylistTracks(backend: backend, playlist: name)
            try require(!tracks.isEmpty, "Couldn't load tracks for '\(name)'.")
            try require(pos >= 1 && pos <= tracks.count, "Track \(pos) is out of range.")
            store.set(AppQueue(playlistName: name, tracks: tracks, currentIndex: pos))
            try require(playQueueTrack(backend: backend, playlist: name, position: pos), "Couldn't play '\(name)'.")
        }
    }
    private func playPlaylist(shuffle: Bool) {
        // Whole-playlist play uses Music's native (gapless) queue — relinquish the
        // app-owned queue so the poller reads Music's context again.
        appQueue.clear()
        let esc = escapeAppleScriptString(playlists[plCursor])
        let name = playlists[plCursor]
        actions.run("Play") {
            try require((try? syncRun { try await self.backend.runMusic("set shuffle enabled to \(shuffle)") }) != nil,
                        "Couldn't set shuffle for '\(name)'.")
            try require((try? syncRun { try await self.backend.runMusic("play playlist \"\(esc)\"") }) != nil,
                        "Couldn't play '\(name)'.")
        }
    }

    // MARK: render helpers (relocated from runPlaylistBrowser, region-relative)

    private func renderRail(_ z: PlaylistZones, into out: inout String, bodyTop: Int, bodyBottom: Int) {
        let listY = bodyTop + 2
        let maxVisible = max(1, bodyBottom - listY)
        let vis = visibleIndices()
        if vis.isEmpty {
            out += ANSICode.moveTo(row: listY, col: z.railX) + "\(ANSICode.dim)(no matches)\(ANSICode.reset)"
            return
        }
        let pos = vis.firstIndex(of: plCursor) ?? 0
        if pos < plScroll { plScroll = pos }
        if pos >= plScroll + maxVisible { plScroll = pos - maxVisible + 1 }
        let end = min(vis.count, plScroll + maxVisible)
        let nameWidth = z.railWidth - 2 - metaCol - 1
        for p in plScroll..<end {
            let i = vis[p]
            let row = listY + (p - plScroll)
            out += ANSICode.moveTo(row: row, col: z.railX)
            let m = meta[i]
            let display = m.name.hasPrefix("__radio__") ? String(m.name.dropFirst("__radio__".count)) : m.name
            let nm = railName(display, nameWidth: max(1, nameWidth))
            let metaCell: String
            if !m.loaded {
                metaCell = "\(ANSICode.dim)\(String(repeating: " ", count: metaCol - 1))\u{00B7}\(ANSICode.reset)"
            } else if let (text, color) = badgeText(m) {
                let padded = String(repeating: " ", count: max(0, metaCol - text.count)) + text
                metaCell = "\(color)\(padded)\(ANSICode.reset)"
            } else {
                let c = "\(m.trackCount ?? 0)"
                let padded = String(repeating: " ", count: max(0, metaCol - c.count)) + c
                metaCell = "\(ANSICode.dim)\(padded)\(ANSICode.reset)"
            }
            let padName = nm + String(repeating: " ", count: max(0, nameWidth - nm.count))
            if i == plCursor {
                // One selection language across the shell: inverse-video when
                // this zone has focus (matches Up Next), dim bar otherwise.
                if focus == .playlists {
                    out += "\u{258C} \(ANSICode.inverse)\(padName)\(ANSICode.reset) \(metaCell)"
                } else {
                    out += "\(ANSICode.dim)\u{258C}\(ANSICode.reset) \(ANSICode.brightWhite)\(padName)\(ANSICode.reset) \(metaCell)"
                }
            } else {
                out += "  \(ANSICode.white)\(padName)\(ANSICode.reset) \(metaCell)"
            }
        }
    }

    private func renderHero(_ z: PlaylistZones, into out: inout String, bodyTop: Int, bodyBottom: Int) {
        var y = bodyTop
        let m = meta[plCursor]
        let title = m.name.hasPrefix("__radio__") ? String(m.name.dropFirst("__radio__".count)) : m.name
        out += ANSICode.moveTo(row: y, col: z.heroX)
        out += "\(ANSICode.bold)\(ANSICode.brightWhite)\(truncText(title, to: z.heroWidth))\(ANSICode.reset)"
        y += 1
        out += ANSICode.moveTo(row: y, col: z.heroX)
        if m.loaded, let c = m.trackCount {
            let dur = m.durationSec.map { " \u{00B7} " + formatPlaylistDuration($0) } ?? ""
            out += "\(ANSICode.dim)\(c) tracks\(dur)\(ANSICode.reset)"
        }
        y += 2
        // Match the Now tab's art size (44×22), clamped to the hero column and to
        // the rows available so the badge + key hints below always fit (same
        // row-reservation discipline as NowPlayingScene's left pane).
        let gw = min(44, z.heroWidth)
        let gh = max(0, min(22, bodyBottom - y - 4))
        var artLines: [String]? = nil
        if let entry = artMap[title.lowercased().trimmingCharacters(in: .whitespaces)] {
            artLines = artwork.lines(key: entry.id,
                                     url: ArtworkStore.resolveURL(entry.url, width: 300, height: 300),
                                     width: gw, height: gh) { [weak self] in
                guard let self else { return }
                self.inboxLock.lock(); self.artDirty = true; self.inboxLock.unlock()
            }
        }
        if let art = artLines {
            let blank = String(repeating: " ", count: gw)
            let rows = art.prefix(gh) + Array(repeating: blank, count: max(0, gh - art.count))
            for line in rows {
                out += ANSICode.moveTo(row: y, col: z.heroX) + line + ANSICode.reset
                y += 1
            }
        } else {
            let block = gradientBlock(name: m.name, width: gw, height: gh)
            var seed = 0; for b in m.name.unicodeScalars { seed = (seed &* 31 &+ Int(b.value)) & 0xffffff }
            let r = 80 + (seed & 0x7f), g = 80 + ((seed >> 8) & 0x7f), bl = 80 + ((seed >> 16) & 0x7f)
            let color = "\u{1B}[38;2;\(r);\(g);\(bl)m"
            for line in block {
                out += ANSICode.moveTo(row: y, col: z.heroX) + "\(color)\(line)\(ANSICode.reset)"
                y += 1
            }
        }
        y += 1
        if let (text, c) = badgeText(m) {
            out += ANSICode.moveTo(row: y, col: z.heroX) + "\(c)\(text)\(ANSICode.reset)"
            y += 2
        } else { y += 1 }
        out += ANSICode.moveTo(row: y, col: z.heroX)
        out += "\(ANSICode.lime)[Enter]\(ANSICode.reset) Browse   \(ANSICode.lime)[P]\(ANSICode.reset) Play   \(ANSICode.lime)[S]\(ANSICode.reset) Shuffle   \(ANSICode.lime)[/]\(ANSICode.reset) Filter"
    }

    private func renderPreview(_ z: PlaylistZones, into out: inout String, bodyTop: Int, bodyBottom: Int) {
        guard z.mode == .three, let rx = z.rightX else { return }
        var y = bodyTop
        out += ANSICode.moveTo(row: y, col: rx) + "\(ANSICode.cyan)Preview\(ANSICode.reset)"; y += 1
        out += ANSICode.moveTo(row: y, col: rx) + "\(ANSICode.dim)\(String(repeating: "\u{2500}", count: min(z.rightWidth, 18)))\(ANSICode.reset)"; y += 1
        if let lines = previewLines[plCursor] {
            if lines.isEmpty {
                out += ANSICode.moveTo(row: y, col: rx) + "\(ANSICode.dim)(empty)\(ANSICode.reset)"
            } else {
                let maxLines = max(1, bodyBottom - y + 1)
                for (i, line) in lines.prefix(maxLines).enumerated() {
                    out += ANSICode.moveTo(row: y, col: rx)
                    let idx = String(format: "%02d", i + 1)
                    out += "\(ANSICode.dim)\(idx)\(ANSICode.reset)  \(truncText(line, to: max(2, z.rightWidth - 4)))"
                    y += 1
                }
            }
        } else {
            out += ANSICode.moveTo(row: y, col: rx) + "\(ANSICode.dim)Loading preview\u{2026}\(ANSICode.reset)"
        }
    }

    private func renderTrackList(_ z: PlaylistZones, into out: inout String, bodyTop: Int, bodyBottom: Int) {
        guard z.mode == .three, let rx = z.rightX else { return }
        var y = bodyTop
        let tracks = fullCache[plCursor]?.tracks ?? []
        out += ANSICode.moveTo(row: y, col: rx) + "\(ANSICode.cyan)Tracks\(ANSICode.reset) \(ANSICode.dim)\(tracks.count)\(ANSICode.reset)"; y += 1
        out += ANSICode.moveTo(row: y, col: rx) + "\(ANSICode.dim)\(String(repeating: "\u{2500}", count: min(z.rightWidth, 18)))\(ANSICode.reset)"; y += 1
        if fullCache[plCursor] == nil {
            out += ANSICode.moveTo(row: y, col: rx) + "\(ANSICode.dim)Loading\u{2026}\(ANSICode.reset)"
            return
        }
        let maxVis = max(1, bodyBottom - y)
        if trCursor < trScroll { trScroll = trCursor }
        if trCursor >= trScroll + maxVis { trScroll = trCursor - maxVis + 1 }
        let end = min(tracks.count, trScroll + maxVis)
        for i in trScroll..<end {
            out += ANSICode.moveTo(row: y, col: rx)
            let idx = String(format: "%02d", i + 1)
            let text = truncText(tracks[i], to: max(2, z.rightWidth - 4))
            if i == trCursor {
                out += "\(ANSICode.inverse)\(idx)  \(text)\(ANSICode.reset)"
            } else {
                out += "\(ANSICode.dim)\(idx)\(ANSICode.reset)  \(text)"
            }
            y += 1
        }
    }
}
