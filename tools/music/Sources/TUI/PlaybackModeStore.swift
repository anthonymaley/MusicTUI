// Which backend MusicTUI drives, persisted at ~/.config/music/mode.json.
//
// Source Mode v1 (docs/plans/2026-09-12-source-mode-v1-spec.md, Anthony's GO
// 2026-09-13). ONE selection governs both playback and catalogue access; there
// is deliberately no second switch.
//
// Its own file, NOT a field on AuthConfig, and that is load-bearing rather than
// tidy: AuthConfig requires keyId, teamId, keyPath and storefront, so a user
// with no developer key has no credential object to store a preference in. The
// whole point of Source Mode is working without that key, so the mode had to
// outlive its absence (Codex I3).
//
// This replaces the MUSICTUI_SOURCE_APP environment variable, which could not be
// discovered, could not be changed without restarting, and could not show its
// own state.
import Foundation

/// Which player MusicTUI controls, and where its catalogue reads come from.
enum PlaybackMode: Equatable, Hashable {
    /// Today's AppleScript player, AirPlay outputs, and the existing
    /// developer-key and keyless paths. The default, always.
    case musicApp
    /// The MusicTUISource app's MusicKit player, sent to the Mac's configured
    /// output, with catalogue reads brokered through it and no developer key.
    case source
    /// SpanDAC on another device (an iPad), reached over the paired network
    /// link, named by its `spandac_id`. The same `slice.*` wire and the same
    /// routing as `.source` (the pairing design, section 4.2); only the
    /// carrier differs.
    case networkSource(String)

    /// The `mode` value in `mode.json`.
    var storedValue: String {
        switch self {
        case .musicApp: return "music_app"
        case .source: return "musictui_source"
        case .networkSource: return "spandac_network"
        }
    }

    /// True for every output a SpanDAC serves over the `slice.*` wire, on this
    /// Mac or on the network: the question almost every caller means when it
    /// asks "is Bridge selected".
    var usesSource: Bool {
        switch self {
        case .musicApp: return false
        case .source, .networkSource: return true
        }
    }

    /// The SpanDAC this mode names, when it names one on the network.
    var networkSourceID: String? {
        if case .networkSource(let id) = self { return id }
        return nil
    }
}

final class PlaybackModeStore {

    private let path: String
    private let lock = NSLock()

    init(path: String = NSString(string: "~/.config/music/mode.json").expandingTildeInPath) {
        self.path = path
    }

    /// The cross-process output lock's file, beside `mode.json` (slice 3, D6),
    /// so a test's temp store gets a temp lock with no further wiring. It is
    /// never replaced and never deleted; see `OutputLock`.
    var lockPath: String {
        ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent("output.lock")
    }

    private struct Stored: Codable {
        let mode: String
        /// The `spandac_id` a `spandac_network` selection names. Absent for
        /// the other two values, so their files are byte-identical to before.
        var target: String?
    }

    /// Music.app unless a stored selection says otherwise.
    ///
    /// Every failure reads as the default: a missing file, an unreadable one, a
    /// corrupt one, or a value this build does not know. A preference that
    /// cannot be read is not a reason to refuse to start, and falling back to
    /// the shipping behaviour is the safe direction. An unknown value
    /// specifically matters for downgrades: a future mode must not be honoured
    /// by a build that cannot serve it.
    ///
    /// **`spandac_network` is a new VALUE, not a field beside
    /// `musictui_source`** (the pairing design, 4.2). An older build decodes an
    /// unknown value as Music.app, by the rule above; a field would be dropped
    /// by its decoder and it would quietly drive the Mac's own socket instead
    /// of the device the person chose. A `spandac_network` with no usable
    /// `target` cannot be served either, so it reads as the default too.
    func mode() -> PlaybackMode {
        lock.lock(); defer { lock.unlock() }
        guard let data = FileManager.default.contents(atPath: path),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return .musicApp }
        switch stored.mode {
        case "music_app": return .musicApp
        case "musictui_source": return .source
        case "spandac_network":
            guard let target = stored.target, SpanDACPair.isCanonicalID(target) else { return .musicApp }
            return .networkSource(target)
        default: return .musicApp
        }
    }

    /// Written atomically. A bare write truncates then refills, so a crash
    /// mid-write leaves a short file that reads as corrupt; this repo has
    /// already measured that failure in the result cache (687 decode failures
    /// in two seconds of interleaved reads and writes, 2026-08-31).
    @discardableResult
    func set(_ mode: PlaybackMode) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(Stored(mode: mode.storedValue, target: mode.networkSourceID))
        else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
