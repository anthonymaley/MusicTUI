// tools/music/Sources/DJ/DJSeams.swift
//
// Everything the DJ box reaches outside itself, as one value the scene holds.
// The defaults FAIL CLOSED: a scene built without wiring cannot ask a model,
// run a script, queue anything or hand anything to Music. The shell wires the
// real ones (`live`); a test hands in fakes and never touches a real player.
import Foundation

struct DJSeams {
    /// Turns a request into a card. The real one is Apple's on-device model.
    var reader: DJReader = DJUnavailableReader(.builtWithoutDJ)
    /// Runs the library genre read inside `tell application "Music"` under a
    /// timeout (seconds). The real one is `AppleScriptBackend.runMusicBlocking`.
    var runScript: (String, TimeInterval) throws -> String = { _, _ in
        throw ActionError(message: "The DJ's library read isn't wired in this build.")
    }
    /// SpanDAC's genre read, built from the Mac's data client.
    var spandacGenre: (SourceAppClient) -> DJSpanDACGenreSource = { DJSpanDACGenreClient(client: $0) }
    /// How long one reader call may take before the box gives up on it (seconds).
    var readerTimeout: TimeInterval = djReaderTimeoutSeconds
    /// The app-owned queue a MusicTUI-data genre play sets.
    var appQueue = AppQueueStore()
    /// Plays the queue's current entry on the MusicTUI output; false on failure.
    var playFirst: (AppQueue) -> Bool = { _ in false }
    /// Plays SpanDAC library rows on the MusicTUI output by verified alias.
    var handoff: MusicTUIHandoff = RefusingHandoff()
    var shuffler: DJShuffling = DJSystemShuffle()
    var now: () -> Date = { Date() }

    /// The shell's wiring: Apple's model, the real AppleScript runner, the
    /// shell's queue store and hand-off. Constructs nothing and reads nothing
    /// until the person asks.
    static func live(backend: AppleScriptBackend, appQueue: AppQueueStore, handoff: MusicTUIHandoff) -> DJSeams {
        var seams = DJSeams()
        seams.reader = DJReaders.makeDefault()
        seams.runScript = { script, timeout in try backend.runMusicBlocking(script, timeout: timeout) }
        seams.appQueue = appQueue
        seams.playFirst = { queue in
            playRequestedQueueTrack(backend: backend, appQueue: appQueue, playlist: queue.playlistName,
                                    position: queue.currentSourcePosition, title: queue.contextLabel)
        }
        seams.handoff = handoff
        return seams
    }
}
