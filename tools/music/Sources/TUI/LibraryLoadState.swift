// tools/music/Sources/TUI/LibraryLoadState.swift
//
// The bulk Library read has two outcomes that an empty array cannot tell apart:
// the library really is empty, or the read failed. `LibraryIndexCache` used to
// take `() -> [LibraryTrackRow]`, so a failure arrived as `[]`, was cached as a
// successful answer, and the tab rendered "(no albums)" permanently - with no
// failure left for a retry to act on.
//
// Failure is now its own case. `[]` means one thing: a successful read of an
// empty library.

import Foundation

/// Outcome of one bulk Library read.
enum LibraryReadResult: Equatable {
    case success([LibraryTrackRow])
    case failure
}

/// What the Library tab should be showing.
enum LibraryStatus: Equatable {
    /// First read in flight, nothing to show yet.
    case loading
    /// Data present. There is no "data present but refresh failed" state: the
    /// Library index is read once per scene and never invalidated, so a read is
    /// never attempted while data exists and therefore can never fail there. If
    /// a refresh operation is ever added, its failure semantics belong with it.
    case ready
    /// No data and the read failed, with retries still to come.
    case unreadableRetrying
    /// No data, retry budget spent. Offers a manual retry.
    case unreadableExhausted
}

/// Decide what to show. Pure.
///
/// The invariant this exists to hold: "empty" is reachable ONLY from a
/// successful read, so a failure can never render as an empty library.
func libraryStatus(hasData: Bool, lastReadFailed: Bool, retriesExhausted: Bool) -> LibraryStatus {
    if hasData { return .ready }
    guard lastReadFailed else { return .loading }
    return retriesExhausted ? .unreadableExhausted : .unreadableRetrying
}

/// Bounded automatic-retry budget: three attempts total, then stop and wait for
/// a person. Deliberately small - a TUI that cannot read the library should say
/// so quickly rather than spin.
struct LibraryRetryBudget: Equatable {
    static let maxAttempts = 3

    private(set) var attempts = 0
    var exhausted: Bool { attempts >= Self.maxAttempts }

    mutating func recordFailure() { attempts += 1 }

    /// A manual retry (`r`) resets the budget, so the user is never told
    /// "press r to retry" by something that has stopped trying for good.
    mutating func reset() { attempts = 0 }

    /// Backoff before attempt `n`, capped. Short on purpose: the read itself is
    /// ~0.85s, and a person is watching.
    static func delay(forAttempt n: Int) -> TimeInterval {
        min(4.0, 0.5 * pow(2.0, Double(max(1, n) - 1)))
    }
}

/// Whether a subview may render its "(no albums)" style empty text.
///
/// Only a successful read that genuinely returned zero rows earns it. A failure
/// rendering as an empty library is the defect this whole model exists to
/// remove, so the rule lives here rather than as a condition in the scene.
func libraryShowsEmptyText(status: LibraryStatus, rowCount: Int) -> Bool {
    status == .ready && rowCount == 0
}

/// Shared load state for the Library tab.
///
/// Albums, songs and artists are three views of ONE bulk read, so the in-flight
/// guard and the retry budget belong here, once, rather than to each list.
/// Per-list budgets would mean nine reads of a failing Music.app and an attempt
/// budget silently multiplied by three.
final class LibraryLoadCoordinator {
    private let lock = NSLock()
    private var budget = LibraryRetryBudget()
    private var reading = false
    private var failed = false

    /// Claim the right to run the shared bulk read.
    ///
    /// Exactly one caller wins while a read is in flight; the others are refused
    /// and simply render from whatever the shared state already says. Refused
    /// too once the budget is spent: at that point the tab is waiting for a
    /// person, not for another attempt.
    func claimRead() -> Bool {
        if case .granted = claim() { return true }
        return false
    }

    /// Why a caller was refused, which changes what it should do next.
    enum ReadClaim: Equatable {
        /// This caller performs the read and must call `finishRead`.
        case granted
        /// Another list is mid-read. Wait for it, then claim again: on success
        /// the cache is warm and the retry costs nothing; on failure this
        /// caller becomes the next budgeted attempt rather than an extra one.
        case inFlight
        /// Budget spent. Do not read; render the status and wait for `r`.
        case stopped
    }

    func claim() -> ReadClaim {
        lock.lock(); defer { lock.unlock() }
        if reading { return .inFlight }
        if failed && budget.exhausted { return .stopped }
        reading = true
        return .granted
    }

    /// Block until any in-flight read finishes, bounded so a wedged read can
    /// never hang a caller forever. Never called on the render or input loop.
    func awaitInFlight(timeout: TimeInterval = 90) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock(); let busy = reading; lock.unlock()
            if !busy { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    /// Report the outcome of a claimed read. A success clears the failure and
    /// restores the budget, so a later blip gets a full three attempts again.
    func finishRead(success: Bool) {
        lock.lock(); defer { lock.unlock() }
        reading = false
        if success {
            failed = false
            budget.reset()
        } else {
            failed = true
            budget.recordFailure()
        }
    }

    var readFailed: Bool { lock.lock(); defer { lock.unlock() }; return failed }
    var exhausted: Bool { lock.lock(); defer { lock.unlock() }; return budget.exhausted }

    /// Backoff before the next automatic attempt.
    var retryDelay: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return LibraryRetryBudget.delay(forAttempt: budget.attempts)
    }

    /// `r`. Resets the attempt budget so a stopped controller reads again.
    func manualRetry() {
        lock.lock(); defer { lock.unlock() }
        budget.reset()
    }

    /// The status a subview shows, given whether IT has rows to render.
    func status(hasData: Bool) -> LibraryStatus {
        lock.lock()
        let f = failed, e = budget.exhausted
        lock.unlock()
        return libraryStatus(hasData: hasData, lastReadFailed: f, retriesExhausted: e)
    }
}

/// Human-facing text for a status, or nil when there is nothing to say.
///
/// Kept beside the state rather than in the scene so the wording cannot drift
/// from the state that produced it.
func libraryStatusMessage(_ status: LibraryStatus) -> String? {
    switch status {
    case .loading, .ready:      return nil
    case .unreadableRetrying:   return "Couldn't read the Music library - retrying"
    case .unreadableExhausted:  return "Couldn't read the Music library - press r to retry"
    }
}
