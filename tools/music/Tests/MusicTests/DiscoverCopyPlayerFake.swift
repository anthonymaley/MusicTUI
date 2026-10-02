import Foundation
@testable import music

/// A scripted fake of `DiscoverCopyPlayerControlling` (score step C3; reused by
/// C6). It is a small model of Music.app playing one copy: `playCopy` starts
/// track 1, `pause`/`play`/`stop` change the state, `nextTrack` steps, and
/// every `confirm` on a playing track advances the position by
/// `positionStepMS`. Each answer can be replaced by setting the matching
/// `on…` closure (return nil from it to fall through to the model).
///
/// Every call is recorded in `calls`, in order: `"trackCount"`, `"read:<k>"`,
/// `"playCopy"`, `"pause"`, `"nextTrack"`, `"play"`, `"stop"`,
/// `"stopIfCurrent"`, `"firstPlay:<track>"`,
/// `"landing:<expected>:<previous>:<settling>"`, `"confirm:<track>"`.
/// `onCall` is told each name as it is recorded (before the answer is made).
final class FakeDiscoverCopyPlayer: DiscoverCopyPlayerControlling {
    enum State: Equatable { case stopped, playing, paused }

    /// The copy's own hex; a call for another hex sees no copy.
    var hex: String
    var ids: [String]
    var trackK: DiscoverCopyTrack
    /// The copy's tracks as Music.app would count them; nil = unreadable.
    /// A queue: each `trackCount` takes the first, and the last one repeats.
    /// Empty answers `ids.count`.
    var trackCounts: [Int?] = []
    var readFails = false

    // The model.
    var state: State = .stopped
    var currentPlaylist: String?
    var currentIndex: Int?            // 0-based into `ids`
    var positionMS = 0
    var positionStepMS = 100

    // Command results.
    var playCopyResult = true
    var pauseResult = true
    var nextTrackResult = true
    var playResult = true
    var stopResult = true

    // Overrides. nil (or a nil answer) = the model answers.
    var onCall: ((String) -> Void)?
    var onFirstPlay: ((String) -> DiscoverCopyPoll?)?
    var onLanding: ((_ expected: String, _ previous: String, _ settling: Bool) -> DiscoverCopyPoll?)?
    var onConfirm: ((String) -> DiscoverCopyConfirm?)?
    /// Runs after the model applied a successful `nextTrack` (to move it elsewhere).
    var afterNextTrack: (() -> Void)?
    /// Runs after the model applied a successful `play`.
    var afterPlay: (() -> Void)?

    private(set) var calls: [String] = []

    init(hex: String, ids: [String], trackK: DiscoverCopyTrack) {
        self.hex = hex
        self.ids = ids
        self.trackK = trackK
    }

    /// The calls that command the player (everything but reads and polls).
    var commands: [String] {
        calls.filter { ["playCopy", "pause", "nextTrack", "play", "stop", "stopIfCurrent"].contains($0) }
    }

    private func record(_ name: String) {
        calls.append(name)
        onCall?(name)
    }

    private var currentTrack: String? {
        guard let index = currentIndex, ids.indices.contains(index) else { return nil }
        return ids[index]
    }

    func trackCount(hex: String) -> Int? {
        record("trackCount")
        guard hex == self.hex else { return 0 }
        guard !trackCounts.isEmpty else { return ids.count }
        return trackCounts.count > 1 ? trackCounts.removeFirst() : trackCounts[0]
    }

    func read(hex: String, k: Int) -> DiscoverCopyRead? {
        record("read:\(k)")
        guard hex == self.hex, !readFails, k >= 1, k <= ids.count else { return nil }
        return DiscoverCopyRead(ids: ids, trackK: trackK)
    }

    func playCopy(hex: String) -> Bool {
        record("playCopy")
        guard playCopyResult, hex == self.hex else { return false }
        state = .playing
        currentPlaylist = hex
        currentIndex = 0
        positionMS = 0
        return true
    }

    func pause() -> Bool {
        record("pause")
        guard pauseResult else { return false }
        if state == .playing { state = .paused }
        return true
    }

    func nextTrack() -> Bool {
        record("nextTrack")
        guard nextTrackResult else { return false }
        if let index = currentIndex { currentIndex = index + 1 }
        positionMS = 0
        afterNextTrack?()
        return true
    }

    func play() -> Bool {
        record("play")
        guard playResult else { return false }
        if state != .stopped || currentIndex != nil { state = .playing }
        afterPlay?()
        return true
    }

    func stop() -> Bool {
        record("stop")
        guard stopResult else { return false }
        state = .stopped
        return true
    }

    func stopIfCurrent(hex: String) -> Bool {
        record("stopIfCurrent")
        if currentPlaylist == hex { state = .stopped }
        return true
    }

    func firstPlay(hex: String, track: String) -> DiscoverCopyPoll {
        record("firstPlay:\(track)")
        if let scripted = onFirstPlay?(track) { return scripted }
        guard state == .playing, currentPlaylist == hex, let current = currentTrack else { return .notYet }
        return current == track ? .landed : .wrongTrack
    }

    func landing(hex: String, expected: String, previous: String, settling: Bool) -> DiscoverCopyPoll {
        record("landing:\(expected):\(previous):\(settling)")
        if let scripted = onLanding?(expected, previous, settling) { return scripted }
        if let playlist = currentPlaylist, playlist != hex { return .foreign }
        if state != .paused { return settling ? .notYet : .wrongState }
        guard currentPlaylist != nil, let current = currentTrack else { return .notYet }
        if current == expected { return .landed }
        if current == previous { return .notYet }
        return .wrongTrack
    }

    func confirm(hex: String, track: String) -> DiscoverCopyConfirm {
        record("confirm:\(track)")
        if let scripted = onConfirm?(track) { return scripted }
        if let playlist = currentPlaylist, playlist != hex { return .foreign }
        guard currentPlaylist != nil, let current = currentTrack else { return .notYet }
        if current != track { return .wrongTrack }
        guard state == .playing else { return .notYet }
        defer { positionMS += positionStepMS }
        return .onTrack(positionMS: positionMS)
    }
}
