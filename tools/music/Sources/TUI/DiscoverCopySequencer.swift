// tools/music/Sources/TUI/DiscoverCopySequencer.swift
//
// S5-S14 of Discover "play from here" on Apple's own copy of a playlist.
//
// `play track N of <playlist>` plays one song and stops, so the only way to
// keep the playlist going is: start it, pause at once, step forward while
// paused, then play. Nothing here waits a fixed time and then assumes: every
// landing is POLLED against the exact persistent ID, in the right playlist, to
// a bound. Any mismatch stops and refuses.
//
// Each command that changes the player (`play pl`, `next track`, `play`) and
// the mode switch go through the `gate` (score section 1.6). Reads, polls,
// `pause`, `stop` and cleanup never do: silencing and cleanup must run whatever
// moved.
import Foundation

// MARK: - The typed Music.app seam

/// S7: the copy's track IDs in order, and track k's title, artist and length.
struct DiscoverCopyRead: Equatable {
    let ids: [String]
    let trackK: DiscoverCopyTrack
}

enum DiscoverCopyPoll: Equatable { case landed, notYet, foreign, wrongState, wrongTrack }

enum DiscoverCopyConfirm: Equatable { case onTrack(positionMS: Int), notYet, foreign, wrongTrack }

protocol DiscoverCopyPlayerControlling {
    func trackCount(hex: String) -> Int?                       // nil = unreadable; a missing copy is 0
    func read(hex: String, k: Int) -> DiscoverCopyRead?        // S7: ordered IDs + track k's title, artist, length
    func playCopy(hex: String) -> Bool                         // `play pl`
    func pause() -> Bool
    func nextTrack() -> Bool
    func play() -> Bool
    func stop() -> Bool
    func stopIfCurrent(hex: String) -> Bool                    // stops only when the current playlist is hex (CH13)
    func firstPlay(hex: String, track: String) -> DiscoverCopyPoll           // S11, k > 1
    func landing(hex: String, expected: String, previous: String,
                 settling: Bool) -> DiscoverCopyPoll                         // S11's pause and S12
    func confirm(hex: String, track: String) -> DiscoverCopyConfirm          // S13
}

// MARK: - The scripts (bodies run inside `tell application "Music"`)

let discoverCopyOKToken = "ok"
let discoverCopyStoppedToken = "stopped"
let discoverCopyLeftToken = "left"
let discoverCopyLandedToken = "landed"
let discoverCopyNotYetToken = "notyet"
let discoverCopyForeignToken = "foreign"
let discoverCopyWrongStateToken = "wrongstate"
let discoverCopyWrongTrackToken = "wrongtrack"
let discoverCopyOnTrackPrefix = "ontrack:"

/// The three reads every poll makes, each inside its own `try`, so an
/// unreadable state, playlist or track is the empty string and never an error.
private let discoverCopyPlayerReads = """
    set stateText to ""
    set ctxID to ""
    set trackID to ""
    try
        set stateText to player state as text
    end try
    try
        set ctxID to persistent ID of current playlist
    end try
    try
        set trackID to persistent ID of current track
    end try
    """

/// S5: how many tracks the copy holds. A missing copy is 0.
func discoverCopyTrackCountScript(hex: String) -> String {
    """
    \(discoverCopyLookupPreamble(hex: hex))
    if pl is missing value then return "0"
    return (count of tracks of pl) as text
    """
}

/// S7: the IDs joined by ASCII 31, then ASCII 30, title, ASCII 30, artist,
/// ASCII 30, the length in whole milliseconds (empty when it has none).
func discoverCopyReadScript(hex: String, k: Int) -> String {
    """
    set fs to (ASCII character 31)
    set rs to (ASCII character 30)
    \(discoverCopyLookupPreamble(hex: hex))
    if pl is missing value then error "the copy is missing"
    set idList to persistent ID of every track of pl
    set AppleScript's text item delimiters to fs
    set idText to idList as text
    set AppleScript's text item delimiters to ""
    set t to track \(k) of pl
    set lengthText to ""
    try
        set lengthText to (round ((duration of t) * 1000) rounding as taught in school) as text
    end try
    return idText & rs & (name of t) & rs & (artist of t) & rs & lengthText
    """
}

/// S11: `play pl`.
func discoverCopyPlayCopyScript(hex: String) -> String {
    """
    \(discoverCopyLookupPreamble(hex: hex))
    if pl is missing value then error "the copy is missing"
    play pl
    return "\(discoverCopyOKToken)"
    """
}

func discoverCopyTransportScript(_ command: String) -> String {
    """
    \(command)
    return "\(discoverCopyOKToken)"
    """
}

/// CH13: stops only when our copy is the current playlist.
func discoverCopyStopIfCurrentScript(hex: String) -> String {
    """
    try
        if persistent ID of current playlist is "\(hex)" then
            stop
            return "\(discoverCopyStoppedToken)"
        end if
    on error
        return "\(discoverCopyNotYetToken)"
    end try
    return "\(discoverCopyLeftToken)"
    """
}

/// S11 (k > 1): playing, in our copy, on `track`.
func discoverCopyFirstPlayScript(hex: String, track: String) -> String {
    """
    \(discoverCopyPlayerReads)
    if stateText is "\(nowPlayingReadyState)" and ctxID is "\(hex)" then
        if trackID is "\(track)" then return "\(discoverCopyLandedToken)"
        if trackID is not "" then return "\(discoverCopyWrongTrackToken)"
    end if
    return "\(discoverCopyNotYetToken)"
    """
}

/// S11's pause and S12: paused, in our copy, on `expected`.
func discoverCopyLandingScript(hex: String, expected: String, previous: String,
                               settling: Bool) -> String {
    let notPaused = settling ? discoverCopyNotYetToken : discoverCopyWrongStateToken
    return """
    \(discoverCopyPlayerReads)
    if ctxID is not "" and ctxID is not "\(hex)" then return "\(discoverCopyForeignToken)"
    if stateText is "" then return "\(discoverCopyNotYetToken)"
    if stateText is not "paused" then return "\(notPaused)"
    if ctxID is "" then return "\(discoverCopyNotYetToken)"
    if trackID is "" then return "\(discoverCopyNotYetToken)"
    if trackID is "\(expected)" then return "\(discoverCopyLandedToken)"
    if trackID is "\(previous)" then return "\(discoverCopyNotYetToken)"
    return "\(discoverCopyWrongTrackToken)"
    """
}

/// S13: playing, in our copy, on `track`, with the position in whole milliseconds.
func discoverCopyConfirmScript(hex: String, track: String) -> String {
    """
    \(discoverCopyPlayerReads)
    if ctxID is not "" and ctxID is not "\(hex)" then return "\(discoverCopyForeignToken)"
    if ctxID is "" then return "\(discoverCopyNotYetToken)"
    if trackID is "" then return "\(discoverCopyNotYetToken)"
    if trackID is not "\(track)" then return "\(discoverCopyWrongTrackToken)"
    if stateText is not "\(nowPlayingReadyState)" then return "\(discoverCopyNotYetToken)"
    set positionText to ""
    try
        set positionText to (round (player position * 1000) rounding as taught in school) as text
    end try
    if positionText is "" then return "\(discoverCopyNotYetToken)"
    return "\(discoverCopyOnTrackPrefix)" & positionText
    """
}

// MARK: - Parsing what the scripts answer

private func discoverCopyTrimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// S7's answer. Exactly four ASCII-30 fields; the first is the IDs joined by
/// ASCII 31. Title and artist are taken as they are (quotes, commas and
/// newlines included). An empty or non-integer length is `durationMS == nil`.
func parseDiscoverCopyRead(_ output: String) -> DiscoverCopyRead? {
    let fields = output.components(separatedBy: "\u{1E}")
    guard fields.count == 4 else { return nil }
    let ids = fields[0].isEmpty ? [] : fields[0].components(separatedBy: "\u{1F}")
    return DiscoverCopyRead(ids: ids,
                            trackK: DiscoverCopyTrack(title: fields[1], artist: fields[2],
                                                      durationMS: Int(discoverCopyTrimmed(fields[3]))))
}

/// Anything unrecognised is `notYet`: never a landing and never an abort.
func parseDiscoverCopyPoll(_ output: String?) -> DiscoverCopyPoll {
    switch output.map(discoverCopyTrimmed) {
    case discoverCopyLandedToken?: return .landed
    case discoverCopyForeignToken?: return .foreign
    case discoverCopyWrongStateToken?: return .wrongState
    case discoverCopyWrongTrackToken?: return .wrongTrack
    default: return .notYet
    }
}

/// Anything unrecognised is `notYet`.
func parseDiscoverCopyConfirm(_ output: String?) -> DiscoverCopyConfirm {
    guard let text = output.map(discoverCopyTrimmed) else { return .notYet }
    if text == discoverCopyForeignToken { return .foreign }
    if text == discoverCopyWrongTrackToken { return .wrongTrack }
    if text.hasPrefix(discoverCopyOnTrackPrefix),
       let ms = Int(text.dropFirst(discoverCopyOnTrackPrefix.count)), ms >= 0 {
        return .onTrack(positionMS: ms)
    }
    return .notYet
}

// MARK: - The AppleScript implementation

/// Every ID that reaches a script is checked to be sixteen `0-9A-F` first; for
/// anything else no script runs and the answer is the failing one.
struct AppleScriptDiscoverCopyPlayer: DiscoverCopyPlayerControlling {
    private let run: ScriptRunner

    init(run: @escaping ScriptRunner) { self.run = run }

    private func succeeded(_ script: String) -> Bool {
        run(script).map(discoverCopyTrimmed) == discoverCopyOKToken
    }

    func trackCount(hex: String) -> Int? {
        guard isPersistentIDHex(hex), let out = run(discoverCopyTrackCountScript(hex: hex)),
              let count = Int(discoverCopyTrimmed(out)), count >= 0 else { return nil }
        return count
    }

    func read(hex: String, k: Int) -> DiscoverCopyRead? {
        guard isPersistentIDHex(hex), k >= 1,
              let out = run(discoverCopyReadScript(hex: hex, k: k)) else { return nil }
        return parseDiscoverCopyRead(out)
    }

    func playCopy(hex: String) -> Bool {
        guard isPersistentIDHex(hex) else { return false }
        return succeeded(discoverCopyPlayCopyScript(hex: hex))
    }

    func pause() -> Bool { succeeded(discoverCopyTransportScript("pause")) }
    func nextTrack() -> Bool { succeeded(discoverCopyTransportScript("next track")) }
    func play() -> Bool { succeeded(discoverCopyTransportScript("play")) }
    func stop() -> Bool { succeeded(discoverCopyTransportScript("stop")) }

    func stopIfCurrent(hex: String) -> Bool {
        guard isPersistentIDHex(hex), let out = run(discoverCopyStopIfCurrentScript(hex: hex)) else { return false }
        let text = discoverCopyTrimmed(out)
        return text == discoverCopyStoppedToken || text == discoverCopyLeftToken
    }

    func firstPlay(hex: String, track: String) -> DiscoverCopyPoll {
        guard isPersistentIDHex(hex), isPersistentIDHex(track) else { return .notYet }
        return parseDiscoverCopyPoll(run(discoverCopyFirstPlayScript(hex: hex, track: track)))
    }

    func landing(hex: String, expected: String, previous: String, settling: Bool) -> DiscoverCopyPoll {
        guard isPersistentIDHex(hex), isPersistentIDHex(expected), isPersistentIDHex(previous) else { return .notYet }
        return parseDiscoverCopyPoll(run(discoverCopyLandingScript(hex: hex, expected: expected,
                                                                  previous: previous, settling: settling)))
    }

    func confirm(hex: String, track: String) -> DiscoverCopyConfirm {
        guard isPersistentIDHex(hex), isPersistentIDHex(track) else { return .notYet }
        return parseDiscoverCopyConfirm(run(discoverCopyConfirmScript(hex: hex, track: track)))
    }
}

// MARK: - The sequencer

struct DiscoverCopySequencer {
    struct Seams {
        var now: () -> Date
        var sleep: (TimeInterval) -> Void
        var gate: DiscoverCopyGate
        var switchModesOff: () -> Bool      // S10
        var restoreModes: () -> Void
        var deleteIfOwned: () -> Void
        var commitListening: () -> Void     // S14, inside the last gate
        var progress: (DiscoverCopyStage) -> Void
        var log: (String) -> Void
    }

    private let player: DiscoverCopyPlayerControlling
    private let seams: Seams

    init(player: DiscoverCopyPlayerControlling, seams: Seams) {
        self.player = player
        self.seams = seams
    }

    /// One poll loop, the only shape of waiting here: read; if the read is
    /// terminal, return it; if the NEXT read would fall past the deadline, time
    /// out (nil); else sleep one cadence.
    private func poll<T>(bound: TimeInterval, cadence: TimeInterval, _ read: () -> T?) -> T? {
        let deadline = seams.now().addingTimeInterval(bound)
        while true {
            if let terminal = read() { return terminal }
            if seams.now().addingTimeInterval(cadence) > deadline { return nil }
            seams.sleep(cadence)
        }
    }

    /// What a gate that did not run means for the result. nil when it ran.
    private func moved(_ answer: DiscoverCopyGateResult) -> DiscoverCopyRefusal? {
        switch answer {
        case .ran: return nil
        case .sourceChanged: return .sourceChanged
        case .superseded: return .superseded
        }
    }

    /// Polls a landing to `bound`; true only for `.landed`.
    private func landed(bound: TimeInterval, _ read: () -> DiscoverCopyPoll) -> Bool {
        let outcome: DiscoverCopyPoll? = poll(bound: bound, cadence: DiscoverCopyTiming.pollCadence) {
            let answer = read()
            return answer == .notYet ? nil : answer
        }
        return outcome == .landed
    }

    func run(hex: String, request: DiscoverCopyRequest) -> DiscoverCopyPlayResult {
        let n = request.rows.count
        let k = request.selected + 1
        let title = request.rows.indices.contains(request.selected) ? request.rows[request.selected].name : ""
        let started = seams.now()
        func elapsed() -> String { String(format: "%.1fs", seams.now().timeIntervalSince(started)) }

        // S5 + S6 (CH4): two reads in a row equal to n are ready; two in a row
        // above n refuse at once; a stable smaller count at the bound refuses
        // as changed, except a stable zero, which is a copy that never loaded;
        // that and anything else at the bound is not ready.
        seams.progress(.waitingForCopy)
        var previous: Int?
        var latest: Int?
        enum Readiness { case ready, tooMany }
        let readiness: Readiness? = poll(bound: DiscoverCopyTiming.readinessBound,
                                         cadence: DiscoverCopyTiming.readinessCadence) {
            previous = latest
            latest = player.trackCount(hex: hex)
            guard let count = latest, count == previous else { return nil }
            if count == n { return .ready }
            if count > n { return .tooMany }
            return nil
        }
        guard readiness == .ready else {
            let stable = latest != nil && latest == previous && latest != 0
            seams.log("discover copy: S5 refused at \(elapsed()), last count \(latest.map(String.init) ?? "unreadable") of \(n)")
            seams.deleteIfOwned()
            return .refused(stable ? .countChanged : .notReady)
        }
        seams.log("discover copy: S5 ready at \(elapsed())")

        // S7: one read. S8: the fixed position, confirmed.
        guard request.rows.indices.contains(request.selected),
              let read = player.read(hex: hex, k: k) else {
            seams.deleteIfOwned()
            return .refused(.unconfirmed(title: title))
        }
        let path: [String]
        switch discoverSubscriptionStart(rows: request.rows, selected: request.selected,
                                         copyIDs: read.ids, trackK: read.trackK) {
        case .start(_, let ids):
            path = ids
        case .refuse(let why):
            seams.log("discover copy: S8 refused: \(why)")
            seams.deleteIfOwned()
            if case .countDiffers = why { return .refused(.countChanged) }
            return .refused(.unconfirmed(title: title))
        }

        // S9 + S10 (G-b): the stamp is validated and the modes switched with
        // nothing able to land between them.
        var modesOff = false
        if let refusal = moved(seams.gate { modesOff = seams.switchModesOff() }) {
            seams.deleteIfOwned()
            return .refused(refusal)
        }
        guard modesOff else {
            seams.restoreModes()
            seams.deleteIfOwned()
            return .refused(.modes)
        }
        seams.progress(.ready)

        // S11 (G-c): start the copy. Nothing of ours has started if the gate moved.
        var playSent = false
        if let refusal = moved(seams.gate { playSent = player.playCopy(hex: hex) }) {
            seams.restoreModes()
            seams.deleteIfOwned()
            return .refused(refusal)
        }
        /// S11's and S13's failure: silence, put the modes back, leave the copy protected.
        func leaveProtected(_ refusal: DiscoverCopyRefusal) -> DiscoverCopyPlayResult {
            _ = player.stop()
            seams.restoreModes()
            return .refused(refusal)
        }
        guard playSent else {
            return leaveProtected(k == 1 ? .wontPlay(title: title) : .firstPlayUnconfirmed)
        }
        seams.progress(.positioning)

        /// After a gate moved once something of ours may be playing.
        func abandon(_ refusal: DiscoverCopyRefusal) -> DiscoverCopyPlayResult {
            _ = player.stopIfCurrent(hex: hex)
            seams.restoreModes()
            seams.deleteIfOwned()
            return .refused(refusal)
        }

        if k > 1 {
            // Song 1 must be the one playing, then paused, before any step.
            guard landed(bound: DiscoverCopyTiming.firstPlayBound, {
                      player.firstPlay(hex: hex, track: path[0])
                  }),
                  player.pause(),
                  landed(bound: DiscoverCopyTiming.pauseSettleBound, {
                      player.landing(hex: hex, expected: path[0], previous: path[0], settling: true)
                  })
            else {
                return leaveProtected(.firstPlayUnconfirmed)
            }

            // S12 (G-d, once per skip): step while paused; each landing polled
            // against the exact ID. No `play()` is ever sent after a failure here.
            for i in 2...k {
                var stepped = false
                if let refusal = moved(seams.gate { stepped = player.nextTrack() }) {
                    return abandon(refusal)
                }
                guard stepped,
                      landed(bound: DiscoverCopyTiming.landingBound, {
                          player.landing(hex: hex, expected: path[i - 1], previous: path[i - 2], settling: false)
                      })
                else {
                    seams.log("discover copy: S12 failed at skip \(i) of \(k)")
                    _ = player.stop()
                    seams.restoreModes()
                    seams.deleteIfOwned()
                    return .refused(.landing(title: title))
                }
            }

            // S13 (G-e): play.
            var resumed = false
            if let refusal = moved(seams.gate { resumed = player.play() }) {
                return abandon(refusal)
            }
            guard resumed else { return leaveProtected(.wontPlay(title: title)) }
        }

        // S13's confirmation: the exact track, in our copy, playing, and its
        // position seen to advance. Never a play of another row.
        var firstPosition: Int?
        enum Confirmation { case advancing, failed }
        let confirmation: Confirmation? = poll(bound: DiscoverCopyTiming.confirmBound,
                                               cadence: DiscoverCopyTiming.pollCadence) {
            switch player.confirm(hex: hex, track: path[k - 1]) {
            case .onTrack(let position):
                guard let first = firstPosition else { firstPosition = position; return nil }
                return position > first ? .advancing : nil
            case .notYet: return nil
            case .foreign, .wrongTrack: return .failed
            }
        }
        guard confirmation == .advancing else {
            seams.log("discover copy: S13 unconfirmed at \(elapsed())")
            return leaveProtected(.wontPlay(title: title))
        }

        // S14 (G-f).
        if let refusal = moved(seams.gate { seams.commitListening() }) {
            return abandon(refusal)
        }
        seams.log("discover copy: listening at \(elapsed())")
        return .listening
    }
}
