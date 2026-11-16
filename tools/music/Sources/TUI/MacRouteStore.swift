// Whether the Mac DAC route is the chosen route, persisted at mac-route.json
// beside mode.json (P8, 2026-11-15). Before this the choice lived in memory
// only: after a TUI restart the Mac row showed unselected and plays took the
// plain path. Its own file, so mode.json is byte-for-byte what it was and an
// older build cannot misread it. Every failure to read is "not chosen".
import Foundation

final class MacRouteStore {
    private let path: String
    private let lock = NSLock()

    private struct Stored: Codable { let on: Bool }

    init(path: String) { self.path = path }

    /// Beside `mode.json`, sharing its directory (a temp mode store gives a temp file).
    convenience init(beside modes: PlaybackModeStore) {
        let dir = (modes.lockPath as NSString).deletingLastPathComponent
        self.init(path: (dir as NSString).appendingPathComponent("mac-route.json"))
    }

    var isOn: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let raw = FileManager.default.contents(atPath: path),
              let stored = try? JSONDecoder().decode(Stored.self, from: raw) else { return false }
        return stored.on
    }

    /// Off removes the file, so a route never chosen leaves nothing behind.
    func set(_ on: Bool) {
        lock.lock(); defer { lock.unlock() }
        if !on {
            try? FileManager.default.removeItem(atPath: path)
            return
        }
        guard let data = try? JSONEncoder().encode(Stored(on: true)) else { return }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
