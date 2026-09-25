// tools/music/Sources/PlaySync/ScriptingBridgeSession.swift
import Foundation
import ScriptingBridge

// The one place that talks to Music.app for play-count write-back.
//
// It is addressed to a process id, never to an application name, with
// `launchFlags = []`, so it cannot launch a Music.app that is not running.
// Verified live only; tests use a fake `MusicLibrarySession` and never build
// one of these.

/// Records the first Apple Event failure of a stage. With a delegate set, a
/// failed event returns nil instead of raising, so an Apple Event failure can
/// never surface as an uncaught exception.
final class AppleEventFailureCapture: NSObject, SBApplicationDelegate {
    private(set) var failure: AEFailure?

    func reset() {
        failure = nil
    }

    func eventDidFail(_ event: UnsafePointer<AppleEvent>, withError error: Error) -> Any? {
        let nsError = error as NSError
        if failure == nil {
            failure = AEFailure(code: nsError.code, message: nsError.localizedDescription)
        }
        return nil
    }
}

/// One connection to one running Music.app, for a single read or write on the
/// calling thread. Never shared across threads.
///
/// Construction fails (Music.app counts as not running) unless the object is
/// attached to a live process with a scripting dictionary. That check comes
/// before any property access: for a pid that has exited, the object exists
/// but has no dictionary, and the first property access would raise an
/// exception that cannot be caught.
final class ScriptingBridgeSession: MusicLibrarySession {
    private let app: SBApplication
    private let capture = AppleEventFailureCapture()

    init?(process: MusicProcess) {
        guard let app = SBApplication(processIdentifier: process.pid) else { return nil }
        app.launchFlags = []
        app.timeout = 600  // ticks: every Apple Event is bounded to about 10 s
        app.delegate = capture
        guard app.isRunning, app.responds(to: NSSelectorFromString("sources")) else { return nil }
        self.app = app
    }

    func matchCount(persistentID: String) -> Result<Int, AEFailure> {
        stage {
            guard let hits = matches(persistentID) else { return nil }
            return hits.count
        }
    }

    func libraryTrackCount() -> Result<Int, AEFailure> {
        stage {
            guard let tracks = libraryTracks() else { return nil }
            return tracks.count
        }
    }

    func playState(persistentID: String) -> Result<TrackPlayState, AEFailure> {
        stage {
            guard let track = track(persistentID),
                  let count = track.value(forKey: "playedCount") as? NSNumber else { return nil }
            let rawDate = track.value(forKey: "playedDate")
            let date: Int?
            switch rawDate {
            case nil, is NSNull: date = nil
            case let value as Date: date = Int(value.timeIntervalSince1970.rounded(.down))
            default: return nil
            }
            return TrackPlayState(count: count.intValue, date: date)
        }
    }

    func setPlayedCount(_ n: Int, persistentID: String) -> Result<Void, AEFailure> {
        stage {
            guard let track = track(persistentID) else { return nil }
            track.setValue(NSNumber(value: n), forKey: "playedCount")
            return ()
        }
    }

    func setPlayedDate(_ epoch: Int, persistentID: String) -> Result<Void, AEFailure> {
        stage {
            guard let track = track(persistentID) else { return nil }
            track.setValue(Date(timeIntervalSince1970: TimeInterval(epoch)), forKey: "playedDate")
            return ()
        }
    }

    /// Runs one stage. An Apple Event failure recorded during the stage fails
    /// it even when a value came back (a failed count can read as zero);
    /// `lastError()` is a second check; a missing or mistyped result with no
    /// recorded failure is an unexpected result.
    private func stage<T>(_ body: () -> T?) -> Result<T, AEFailure> {
        capture.reset()
        let value = body()
        if let failure = capture.failure { return .failure(failure) }
        if let error = app.lastError() {
            let nsError = error as NSError
            return .failure(AEFailure(code: nsError.code, message: nsError.localizedDescription))
        }
        guard let value else {
            return .failure(AEFailure(code: -1, message: MusicAccessSentence.unexpectedResult))
        }
        return .success(value)
    }

    private func libraryTracks() -> SBElementArray? {
        guard let sources = app.value(forKey: "sources") as? SBElementArray,
              let library = sources.object(at: 0) as? SBObject,
              let playlists = library.value(forKey: "libraryPlaylists") as? SBElementArray,
              let playlist = playlists.object(at: 0) as? SBObject else { return nil }
        return playlist.value(forKey: "tracks") as? SBElementArray
    }

    private func matches(_ persistentID: String) -> SBElementArray? {
        libraryTracks()?.filtered(using: NSPredicate(format: "persistentID == %@", persistentID))
            as? SBElementArray
    }

    private func track(_ persistentID: String) -> SBObject? {
        matches(persistentID)?.object(at: 0) as? SBObject
    }
}
