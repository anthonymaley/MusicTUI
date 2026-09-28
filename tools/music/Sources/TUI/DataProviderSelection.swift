// Which selection MusicTUI's DATA comes from, independent of where sound goes
// (score: data route and output, C-AXES). `PlaybackMode`/`PlaybackModeStore`
// keep their names and file unchanged for the OUTPUT axis; this file is the
// DATA axis's own store, in its own file, so an older build that only knows
// how to rewrite `mode.json` cannot drop it.
//
// This step seeds the store and `effectiveSelection` with no caller yet:
// nothing behaves differently until routing (a later step) reads them.
import Foundation

/// Where MusicTUI's music DATA comes from. Independent of where sound goes.
enum DataProviderSelection: Equatable {
    case open
    case spandacMac
}

/// The one-time "Switch MusicTUI to SpanDAC?" screen's own state.
enum SwitchCeremonyState: Equatable {
    case neverShown
    case declined
    case accepted
}

/// The sound axis. `PlaybackMode` keeps its name and file so no call site
/// moves; `.musicApp` is the output a person reads as "MusicTUI" (the
/// internal name is kept; see the naming rule in the score).
typealias OutputSelection = PlaybackMode

/// What the two stored files mean together, after the fail-closed repair rule
/// (C-REPAIR): a stored SpanDAC output with no accepted data state is blocked
/// rather than silently migrated or silently served from the wrong place.
enum EffectiveSelection: Equatable {
    case consistent(data: DataProviderSelection, output: OutputSelection)
    /// A SpanDAC output is stored but data is not accepted: fail closed.
    case outputBlocked(stored: OutputSelection)
}

/// Persists the DATA axis at `data.json`, beside `mode.json`.
///
/// **No migration (Anthony's ruling of 2026-09-28 12:19).** The only accepted
/// data state is exactly `data == .spandacMac` AND `ceremony == .accepted`,
/// both readable together. Everything else — a missing file, a corrupt one, a
/// partially written one, an unknown value, or an explicit `open` or
/// `declined` — reads as `.open`, with whatever ceremony state it names, or
/// `.neverShown` if that too cannot be read. Reads never write.
final class DataProviderStore {

    private let path: String
    private let lock = NSLock()

    private struct Stored: Codable {
        let data: String
        let ceremony: String
    }

    init(path: String) {
        self.path = path
    }

    /// `data.json` lives beside `mode.json`, sharing its directory, so a store
    /// built from a `PlaybackModeStore` needs no separate path of its own.
    convenience init(beside modes: PlaybackModeStore) {
        let dir = (modes.lockPath as NSString).deletingLastPathComponent
        self.init(path: (dir as NSString).appendingPathComponent("data.json"))
    }

    func read() -> (data: DataProviderSelection, ceremony: SwitchCeremonyState) {
        lock.lock(); defer { lock.unlock() }
        guard let raw = FileManager.default.contents(atPath: path),
              let stored = try? JSONDecoder().decode(Stored.self, from: raw)
        else { return (.open, .neverShown) }

        let ceremony: SwitchCeremonyState
        switch stored.ceremony {
        case "declined": ceremony = .declined
        case "accepted": ceremony = .accepted
        default: ceremony = .neverShown
        }

        // SpanDAC data only when the person accepted the switch: a file that
        // names SpanDAC under any other ceremony state (declined, never shown,
        // unknown) is not an accepted data state and reads as open.
        let data: DataProviderSelection =
            (stored.data == "spandac_mac" && ceremony == .accepted) ? .spandacMac : .open
        return (data, ceremony)
    }

    /// Atomic, like `PlaybackModeStore.set` (a bare write's crash-mid-write
    /// leaves a short file that reads as corrupt, which this repo has already
    /// measured elsewhere).
    @discardableResult
    private func write(data: String, ceremony: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let encoded = try? JSONEncoder().encode(Stored(data: data, ceremony: ceremony))
        else { return false }
        do {
            try encoded.write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Accepts SpanDAC as the data source and records the ceremony as shown
    /// and accepted, in one atomic write.
    @discardableResult
    func accept() -> Bool {
        write(data: "spandac_mac", ceremony: "accepted")
    }

    /// Records the ceremony as shown and declined; data stays `.open`.
    @discardableResult
    func decline() -> Bool {
        write(data: "open", ceremony: "declined")
    }

    /// The way back: data returns to `.open`, ceremony recorded as declined
    /// (so the switch screen does not show itself again on its own).
    @discardableResult
    func stopUsingSpanDAC() -> Bool {
        write(data: "open", ceremony: "declined")
    }
}

/// What the two stored files mean together (C-REPAIR): a stored SpanDAC
/// output is only ever live when data is exactly `.spandacMac` with an
/// `.accepted` ceremony; anything else is `.outputBlocked`, never a silent
/// migration to either side.
func effectiveSelection(data: DataProviderStore, modes: PlaybackModeStore) -> EffectiveSelection {
    let output = modes.mode()
    let (dataSelection, ceremony) = data.read()
    guard output.usesSource else {
        return .consistent(data: dataSelection, output: output)
    }
    guard dataSelection == .spandacMac, ceremony == .accepted else {
        return .outputBlocked(stored: output)
    }
    return .consistent(data: .spandacMac, output: output)
}

/// Person-facing sentence used wherever a SpanDAC row is available to choose.
let pickASpanDACOutput = "Pick a SpanDAC output to play this."

/// The person-facing name for the non-SpanDAC output, everywhere a person
/// reads it. Never "Music.app" (that name stays internal: types, cases, and
/// code comments may keep it).
let musicTUIOutputName = "MusicTUI"
