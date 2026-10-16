// tools/music/Sources/TUI/Shell/LibraryRefreshWatch.swift
import Foundation

/// Reads a `slice.libraryRefresh` ask's outcome off `slice.status`'s
/// `library_refresh` fact, for `BridgeListFeed.refresh`'s completion check.
///
/// **Trust.** A fact counts only when its `instance` is the one the op's reply
/// named (a different one means SpanDAC restarted: `restarted`, stop waiting) and
/// its `ticket` is at least the ask's (an older one is not this ask's: `pending`).
/// A status that cannot be read, or carries no fact, is `pending` too; the feed's
/// bound is what ends a wait that never resolves.
///
/// **`joined` is not `started`.** A `joined` ask attached itself to a drain that
/// was already running, which may have read the library before the person
/// pressed `r`. So its ticket is waited out first, and once that ticket ends
/// (installed, failed or cancelled) the op is sent ONCE more and that answer is
/// followed: `started` is the normal path from there, `joined` again or
/// `deferred` stops with the honest verdict for it. Never more than one
/// follow-up. The follow-up goes out from inside `progress()`, which the feed
/// calls from its one worker thread, so no state here is shared.
final class LibraryRefreshWatch {
    typealias Progress = BridgeListFeed<MusicRow>.RefreshProgress

    private let provider: MusicDataProvider
    private var ticket: Int
    private let instance: String
    private var followUpPending: Bool

    /// nil for `deferred`: there is nothing to wait for.
    init?(provider: MusicDataProvider, outcome: SpanDACLibraryRefreshOutcome) {
        self.provider = provider
        switch outcome {
        case .deferred: return nil
        case .started(let t, let i): ticket = t; instance = i; followUpPending = false
        case .joined(let t, let i): ticket = t; instance = i; followUpPending = true
        }
    }

    func progress() -> Progress {
        guard let done = (try? provider.libraryRefreshCompletion()) ?? nil else { return .pending }
        guard done.instance == instance else { return .restarted }
        guard done.ticket >= ticket else { return .pending }
        if followUpPending {
            followUpPending = false
            switch try? provider.libraryRefresh() {
            case .started(let t, let i)?:
                guard i == instance else { return .restarted }
                ticket = t
                return .pending
            case .joined?: return .stillJoined
            case .deferred?: return .deferred
            case nil: return .failed
            }
        }
        return done.result == .installed ? .installed : .failed
    }
}
