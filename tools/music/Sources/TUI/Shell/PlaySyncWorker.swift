// tools/music/Sources/TUI/Shell/PlaySyncWorker.swift
import Foundation

/// Records Bridge's finished library plays in Music.app while the TUI runs.
///
/// It runs on a thread of its own, never the playback poller's thread and never
/// the input loop, so a slow pass cannot stall playback updates or keys. The
/// first pass comes a few seconds after launch, then one every 30 seconds, and
/// only while Bridge is the selected output: with Music.app selected it runs no
/// pass at all, touches neither Bridge nor Music.app, and leaves pending plays
/// for Bridge mode or `music sync-plays`.
///
/// The worker never reads or writes the play-sync journal. Its only dependency
/// is `PlaySyncRunning`; it reads the returned result and nothing else, and
/// whether a problem is new is the pass's decision, not the worker's.
///
/// The status line stays quiet: it hears only about plays just recorded and
/// problems reported for the first time. A pass that did nothing, found Bridge
/// or Music.app not running, or found another sync in progress posts nothing.
final class PlaySyncWorker {

    /// Toast lifetimes, in seconds.
    static let recordedTTL: TimeInterval = 4
    static let problemTTL: TimeInterval = 6
    /// The longest `stop()` waits for a pass in progress.
    static let stopWaitSeconds: TimeInterval = 2

    /// `Recorded 1 library play in Music.app` / `Recorded N library plays in Music.app`.
    static func recordedSentence(_ count: Int) -> String {
        count == 1
            ? "Recorded 1 library play in Music.app"
            : "Recorded \(count) library plays in Music.app"
    }

    /// `1 play not recorded yet — run music sync-plays` / `N plays …`.
    static func problemSentence(_ count: Int) -> String {
        count == 1
            ? "1 play not recorded yet \u{2014} run music sync-plays"
            : "\(count) plays not recorded yet \u{2014} run music sync-plays"
    }

    private let isBridgeSelected: () -> Bool
    private let runner: PlaySyncRunning
    private let post: (_ text: String, _ error: Bool, _ ttl: TimeInterval) -> Void
    private let intervalSeconds: TimeInterval
    private let firstDelaySeconds: TimeInterval

    private let lock = NSLock()
    private var started = false
    private var stopping = false
    /// Signalled by `stop()` to cut a wait between passes short.
    private let wake = DispatchSemaphore(value: 0)
    /// Signalled when the thread's loop returns.
    private let finished = DispatchSemaphore(value: 0)

    init(isBridgeSelected: @escaping () -> Bool, runner: PlaySyncRunning,
         post: @escaping (_ text: String, _ error: Bool, _ ttl: TimeInterval) -> Void,
         intervalSeconds: TimeInterval = 30, firstDelaySeconds: TimeInterval = 5) {
        self.isBridgeSelected = isBridgeSelected
        self.runner = runner
        self.post = post
        self.intervalSeconds = intervalSeconds
        self.firstDelaySeconds = firstDelaySeconds
    }

    /// Starts the worker's own thread. A second call does nothing.
    func start() {
        lock.lock()
        guard !started, !stopping else { lock.unlock(); return }
        started = true
        lock.unlock()
        let thread = Thread { [weak self] in self?.loop() }
        thread.name = "music.play-sync"
        thread.start()
    }

    /// Asks the worker to stop and waits at most two seconds for it. A pass
    /// still running after that is left to finish on its own: anything it was
    /// writing is already saved as in progress, and the next pass settles it.
    func stop() {
        lock.lock()
        let wasStarted = started
        let alreadyStopping = stopping
        stopping = true
        lock.unlock()
        guard wasStarted, !alreadyStopping else { return }
        wake.signal()
        _ = finished.wait(timeout: .now() + Self.stopWaitSeconds)
    }

    /// One tick: a background pass if Bridge is selected, then any news.
    func tickOnce() {
        guard isBridgeSelected() else { return }
        let result = runner.pass(.background)
        guard !isStopping() else { return }
        if !result.recorded.isEmpty {
            post(Self.recordedSentence(result.recorded.count), false, Self.recordedTTL)
        }
        // Posted after the recorded count, so when a pass has both the problem
        // is the toast left showing.
        if !result.newProblems.isEmpty {
            post(Self.problemSentence(result.newProblems.count), true, Self.problemTTL)
        }
    }

    private func isStopping() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return stopping
    }

    private func loop() {
        defer { finished.signal() }
        var delay = firstDelaySeconds
        while true {
            _ = wake.wait(timeout: .now() + delay)
            if isStopping() { return }
            tickOnce()
            delay = intervalSeconds
        }
    }
}
