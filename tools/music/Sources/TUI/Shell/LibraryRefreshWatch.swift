// tools/music/Sources/TUI/Shell/LibraryRefreshWatch.swift
import Foundation

/// Reads a `slice.libraryRefresh` ask's outcome off `slice.status`, for
/// `BridgeListFeed.refresh`'s completion check.
///
/// **Trust.** A restart is seen two ways: `library_instance` (on every status
/// reply on the Mac socket, so it shows while `library_refresh` is still null)
/// differing from the instance the op's reply named, or, where that is absent,
/// the `library_refresh` fact's own `instance` differing. Either is `restarted`:
/// stop waiting. Otherwise the fact counts only when its `ticket` is at least the
/// ask's (an older one is not this ask's: `pending`). A status that cannot be
/// read, or carries no fact, is `pending` too; the feed's bound is what ends a
/// wait that never resolves.
///
/// **`joined` is not `started`.** A `joined` ask attached itself to a drain that
/// was already running, which may have read the library before the person
/// pressed `r`. So its ticket is waited out first, and once that ticket ends
/// (installed, failed or cancelled) the op is sent ONCE more. Whatever drain that
/// answer names, `started` or `joined`, began after the first one ended and so
/// after the keypress: its ticket becomes the one waited on, and its verdict is
/// the answer. Only `deferred` or a refusal stops short. Never more than one
/// follow-up. It goes out from inside `progress()`, which the feed calls from its
/// one worker thread, so no state here is shared.
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
        guard let status = try? provider.libraryRefreshStatus() else { return .pending }
        if let running = status.libraryInstance, running != instance { return .restarted }
        guard let done = status.completion else { return .pending }
        guard done.instance == instance else { return .restarted }
        guard done.ticket >= ticket else { return .pending }
        if followUpPending {
            followUpPending = false
            switch try? provider.libraryRefresh() {
            case .started(let t, let i)?, .joined(let t, let i)?:
                guard i == instance else { return .restarted }
                ticket = t
                return .pending
            case .deferred?: return .deferred
            case nil: return .failed
            }
        }
        return done.result == .installed ? .installed : .failed
    }
}
