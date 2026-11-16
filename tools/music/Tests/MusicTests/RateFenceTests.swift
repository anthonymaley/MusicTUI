// tools/music/Tests/MusicTests/RateFenceTests.swift
//
// MusicTUI's half of the rate transaction (mac-route-plan.md, "Appendix: rate
// transaction protocol", M1 and M3): the fence file under the output lock, the
// lease, and revalidate-to-play under the lock. These are the public client's
// own tests of the guarantees the private reference model only assumed, written
// against the real `OutputLock` (flock) in a temp directory. Two `OutputLock`
// instances on two threads stand in for two processes, and one test runs a
// real second process (perl) against the same files. Waits are semaphores;
// nothing sleeps to produce an ordering.
//
// No audio, no AppleScript, no socket, and never `~/.config/music`.
import XCTest
@testable import music

final class RateFenceTests: XCTestCase {

    // MARK: support

    private func tempDir() -> String { OutputLockTestSupport.tempDir() }

    /// A fence on `dir`, its lock polling fast. `onWaiting` fires when this
    /// instance finds the lock held and starts to wait.
    private func fence(in dir: String, onWaiting: (() -> Void)? = nil) -> RateFence {
        RateFence(lock: OutputLock(path: dir + "/output.lock", pollInterval: 0.001, onWaiting: onWaiting))
    }

    private func raw(_ dir: String, _ name: String = "rate.fence") -> String? {
        try? String(contentsOfFile: dir + "/" + name, encoding: .utf8)
    }

    private let wait: TimeInterval = 10

    // MARK: where it lives

    func testTheFilesLiveBesideTheLockNeverElsewhere() {
        let dir = tempDir()
        let byLock = fence(in: dir)
        XCTAssertEqual(byLock.fencePath, dir + "/rate.fence")
        XCTAssertEqual(byLock.leasePath, dir + "/rate.lease")
        let byStore = RateFence(store: PlaybackModeStore(path: dir + "/mode.json"))
        XCTAssertEqual(byStore.fencePath, dir + "/rate.fence", "the store's lock is output.lock beside mode.json")
        XCTAssertEqual(byStore.lock.path, dir + "/output.lock")
    }

    // MARK: M1

    func testTheFenceStartsAtOneAndGrowsByOneAndTheFilesAreNeverDeleted() throws {
        let dir = tempDir()
        let f = fence(in: dir)
        XCTAssertEqual(try f.current(), 0, "no file yet reads as 0")
        let a = try f.begin(.play, owner: "tui")
        let b = try f.begin(.next, owner: "tui")
        XCTAssertEqual([a.fence, b.fence], [1, 2])
        XCTAssertEqual(raw(dir), "2")
        XCTAssertEqual(raw(dir, "rate.lease"), "tui")
        XCTAssertEqual(try f.current(), 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/rate.fence"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/output.lock"))
    }

    func testTheCommandsAreTheAppendixsList() {
        XCTAssertEqual(Set(RateCommand.allCases.map(\.rawValue)),
                       ["play", "advance", "next", "previous", "jump", "shuffle", "station",
                        "pause", "resume", "seek", "routeChange"])
        XCTAssertFalse(RateCommand.pause.startsSound)
        XCTAssertFalse(RateCommand.routeChange.startsSound)
        XCTAssertTrue(RateCommand.station.startsSound)
        XCTAssertTrue(RateCommand.advance.startsSound)
    }

    /// Every command's work runs after its increment, with the fence already in
    /// the file: the work reads the file itself.
    func testEveryCommandMovesTheFenceBeforeItsWork() throws {
        let dir = tempDir()
        let f = fence(in: dir)
        var seen: [(command: RateCommand, tokenFence: Int, fileInWork: String?)] = []
        for command in RateCommand.allCases {
            _ = try f.run(command, owner: "tui") { token in
                seen.append((command, token.fence, self.raw(dir)))
            }
        }
        XCTAssertEqual(seen.count, RateCommand.allCases.count)
        for (index, entry) in seen.enumerated() {
            XCTAssertEqual(entry.tokenFence, index + 1, "\(entry.command) did not move the fence by one")
            XCTAssertEqual(entry.fileInWork, String(index + 1), "\(entry.command) ran before the file moved")
        }
    }

    /// The increment needs the lock: with another process holding it, a command
    /// does not run at all (fail closed), and the file is untouched.
    func testACommandThatCannotTakeTheLockRunsNothing() throws {
        let dir = tempDir()
        let holder = BackgroundHolder(OutputLock(path: dir + "/output.lock"))
        XCTAssertEqual(holder.acquired.wait(timeout: .now() + wait), .success)
        let f = fence(in: dir)
        var ran = 0
        XCTAssertThrowsError(try f.run(.play, owner: "tui", timeout: 0) { _ in ran += 1 }) {
            XCTAssertEqual($0 as? OutputLockError, .busy)
        }
        XCTAssertEqual(ran, 0)
        XCTAssertNil(raw(dir), "the fence moved without the lock")
        holder.release.signal()
        XCTAssertEqual(holder.done.wait(timeout: .now() + wait), .success)
    }

    /// An unwritable fence file is a refusal, not an unordered play.
    func testAnUnwritableFenceFileRefusesTheCommand() throws {
        let dir = tempDir()
        let f = fence(in: dir)
        _ = try f.begin(.play, owner: "tui")
        XCTAssertEqual(chmod(dir + "/rate.fence", 0o444), 0)
        defer { _ = chmod(dir + "/rate.fence", 0o644) }
        guard geteuid() != 0 else { return }
        var ran = 0
        XCTAssertThrowsError(try f.run(.next, owner: "tui") { _ in ran += 1 }) {
            guard case RateFenceError.unavailable = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(ran, 0)
    }

    // MARK: Monotonic under the lock

    /// Two instances (two threads) taking 150 fences each: all 300 are distinct,
    /// each side's own are strictly increasing, and the file ends at 300.
    func testTheFenceIsMonotonicAcrossTwoInstances() throws {
        let dir = tempDir()
        let a = fence(in: dir), b = fence(in: dir)
        let group = DispatchGroup()
        let log = NSLock()
        var taken: [String: [Int]] = ["a": [], "b": []]
        for (name, f) in [("a", a), ("b", b)] {
            group.enter()
            DispatchQueue.global().async {
                for _ in 0..<150 {
                    if let token = try? f.begin(.play, owner: name) {
                        log.lock(); taken[name, default: []].append(token.fence); log.unlock()
                    }
                }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 60), .success)
        let all = (taken["a"] ?? []) + (taken["b"] ?? [])
        XCTAssertEqual(all.count, 300)
        XCTAssertEqual(Set(all), Set(1...300), "a fence was taken twice or skipped")
        for name in ["a", "b"] {
            let own = taken[name] ?? []
            XCTAssertEqual(own, own.sorted(), "\(name) saw its own fences go backwards")
        }
        XCTAssertEqual(raw(dir), "300")
    }

    /// The deterministic form of the same claim: while another instance holds
    /// the output lock, a second instance's `begin` waits, and moves nothing
    /// until the first lets go.
    func testASecondInstanceWaitsForTheLockBeforeItMovesTheFence() throws {
        let dir = tempDir()
        _ = try fence(in: dir).begin(.play, owner: "seed")
        let holder = BackgroundHolder(OutputLock(path: dir + "/output.lock"))
        XCTAssertEqual(holder.acquired.wait(timeout: .now() + wait), .success)

        let waiting = DispatchSemaphore(value: 0)
        let second = fence(in: dir, onWaiting: { waiting.signal() })
        let done = DispatchGroup()
        var token: RateToken?
        done.enter()
        DispatchQueue.global().async { token = try? second.begin(.next, owner: "second"); done.leave() }

        XCTAssertEqual(waiting.wait(timeout: .now() + wait), .success,
                       "the second begin never found the lock held: it does not take the lock")
        XCTAssertEqual(done.wait(timeout: .now() + 0.05), .timedOut, "it finished while the lock was held")
        XCTAssertEqual(raw(dir), "1", "the fence moved while another holder had the lock")

        holder.release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + wait), .success)
        XCTAssertEqual(token?.fence, 2)
        XCTAssertEqual(raw(dir), "2")
        XCTAssertEqual(holder.done.wait(timeout: .now() + wait), .success)
    }

    /// A real second process, running the same rule (flock `output.lock`, read,
    /// add one, write, release) against the same two files, while this process
    /// takes its own. Together they never repeat a number.
    func testTheFenceIsMonotonicAgainstARealSecondProcess() throws {
        let perl = "/usr/bin/perl"
        guard FileManager.default.isExecutableFile(atPath: perl) else { throw XCTSkip("no perl at \(perl)") }
        let dir = tempDir()
        let f = fence(in: dir)
        _ = try f.begin(.play, owner: "seed")

        let child = Process()
        child.executableURL = URL(fileURLWithPath: perl)
        child.arguments = ["-e", """
            use Fcntl qw(:flock);
            my ($dir, $n) = @ARGV;
            open(my $lk, '>>', "$dir/output.lock") or die "lock: $!";
            for (1..$n) {
                flock($lk, LOCK_EX) or die "flock: $!";
                my $v = 0;
                if (open(my $r, '<', "$dir/rate.fence")) { my $t = <$r>; close $r; $v = $t if defined $t && $t =~ /^\\d+$/; }
                $v++;
                open(my $w, '>', "$dir/rate.fence") or die "write: $!";
                print $w $v; close $w;
                select(undef, undef, undef, 0.001);
                flock($lk, LOCK_UN);
                print "$v\\n";
            }
            """, dir, "60"]
        let out = Pipe()
        child.standardOutput = out
        try child.run()

        var mine: [Int] = []
        for _ in 0..<60 { mine.append(try f.begin(.advance, owner: "tui").fence) }
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
        let theirs = (String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            .split(separator: "\n").compactMap { Int($0) }

        XCTAssertEqual(theirs.count, 60)
        XCTAssertEqual(Set(mine + theirs), Set(2...121), "a fence was repeated or skipped across the two processes")
        XCTAssertEqual(mine, mine.sorted())
        XCTAssertEqual(theirs, theirs.sorted())
        XCTAssertEqual(raw(dir), "121")
    }

    // MARK: A lost file

    /// A missing or unreadable-as-a-number file restarts below SpanDAC's
    /// highest fence; the client answers that as a regression (M4), it does not
    /// refuse. Here: it restarts at 1, and the old token is no longer current.
    func testALostFileRestartsAtOneAndTheOldTokenIsNoLongerCurrent() throws {
        let dir = tempDir()
        let f = fence(in: dir)
        for _ in 0..<5 { _ = try f.begin(.play, owner: "tui") }
        let old = try f.begin(.play, owner: "tui")
        XCTAssertEqual(old.fence, 6)
        try FileManager.default.removeItem(atPath: dir + "/rate.fence")
        XCTAssertEqual(try f.begin(.next, owner: "tui").fence, 1)
        XCTAssertFalse(try f.fenceFileHolds(old.fence))
        try "not a number".write(toFile: dir + "/rate.fence", atomically: false, encoding: .utf8)
        XCTAssertEqual(try f.begin(.next, owner: "tui").fence, 1, "garbage reads as lost, not as a refusal")
    }

    // MARK: M3, revalidate and play under the lock

    /// A newer command cannot come between revalidate and play: its increment
    /// needs the same lock, so it waits until the play has started.
    func testANewerCommandCannotComeBetweenRevalidateAndPlay() throws {
        let dir = tempDir()
        let runner = fence(in: dir)
        let waiting = DispatchSemaphore(value: 0)
        let tui = fence(in: dir, onWaiting: { waiting.signal() })
        let a = try runner.begin(.play, owner: "runner")

        let inPlay = DispatchSemaphore(value: 0), finishPlay = DispatchSemaphore(value: 0)
        let events = OutputLockLog()
        let done = DispatchGroup()
        var verdict: RateRevalidation<String>?
        done.enter()
        DispatchQueue.global().async {
            verdict = try? runner.playIfCurrent(a) { () -> String in
                inPlay.signal()
                finishPlay.wait()
                events.append("runner plays")
                return "Aja"
            }
            done.leave()
        }
        XCTAssertEqual(inPlay.wait(timeout: .now() + wait), .success)

        var newer: RateToken?
        done.enter()
        DispatchQueue.global().async {
            newer = try? tui.begin(.next, owner: "tui")
            events.append("tui moves the fence")
            done.leave()
        }
        XCTAssertEqual(waiting.wait(timeout: .now() + wait), .success,
                       "the newer command's increment did not wait for the lock the play holds")
        XCTAssertEqual(raw(dir), "1", "the fence moved between revalidate and play")
        finishPlay.signal()
        XCTAssertEqual(done.wait(timeout: .now() + wait), .success)

        XCTAssertEqual(verdict, .played("Aja"))
        XCTAssertEqual(newer?.fence, 2)
        XCTAssertEqual(events.all, ["runner plays", "tui moves the fence"])
    }

    /// The other order: the newer increment lands first, the older revalidation
    /// fails, and nothing plays.
    func testANewerCommandBeforeRevalidateInvalidatesTheOlder() throws {
        let dir = tempDir()
        let runner = fence(in: dir), tui = fence(in: dir)
        let a = try runner.begin(.play, owner: "runner")
        let b = try tui.begin(.next, owner: "tui")
        var played: [String] = []
        XCTAssertEqual(try runner.playIfCurrent(a) { played.append("Aja"); return 1 }, .invalidated)
        XCTAssertEqual(try tui.playIfCurrent(b) { played.append("Peg"); return 1 }, .played(1))
        XCTAssertEqual(played, ["Peg"])
        XCTAssertTrue(OutputLockTestSupport.isFree(dir + "/output.lock"), "a revalidation left the lock held")
    }

    /// Negative control: the same check with the lock released between the
    /// revalidate and the play is exactly what M3 forbids, and the stale play
    /// lands. If this stopped failing, the two tests above would prove nothing.
    func testWithoutTheLockSpanAnOlderPlayLandsOverANewerCommand() throws {
        let dir = tempDir()
        let runner = fence(in: dir), tui = fence(in: dir)
        let a = try runner.begin(.play, owner: "runner")
        let stillCurrent = try runner.fenceFileHolds(a.fence)       // revalidate, lock released
        _ = try tui.begin(.next, owner: "tui")                      // a newer command comes between
        var played: [String] = []
        if stillCurrent { played.append("Aja (stale)") }            // play, after the gap
        XCTAssertEqual(played, ["Aja (stale)"], "the unlocked form plays over the newer command")
        XCTAssertFalse(try runner.fenceFileHolds(a.fence))
    }

    /// Supersession in both directions (TUI over the CLI runner, and back): the
    /// older token plays nothing, the newer plays, and the order of the plays is
    /// the order of the fences.
    private func supersede(first: String, second: String) throws {
        let dir = tempDir()
        let older = fence(in: dir), newer = fence(in: dir)
        let a = try older.begin(.play, owner: first)
        let b = try newer.begin(.next, owner: second)
        var played: [String] = []
        XCTAssertEqual(try older.playIfCurrent(a) { played.append(first); return 1 }, .invalidated)
        XCTAssertEqual(try newer.playIfCurrent(b) { played.append(second); return 1 }, .played(1))
        XCTAssertEqual(played, [second])
        XCTAssertEqual([a.fence, b.fence], [1, 2])
    }

    func testTheTUISupersedesTheRunner() throws { try supersede(first: "runner", second: "tui") }
    func testTheRunnerSupersedesTheTUI() throws { try supersede(first: "tui", second: "runner") }

    /// A route change is a fenced command: the transition in flight plays nothing.
    func testARouteChangeInvalidatesTheTransitionInFlight() throws {
        let dir = tempDir()
        let runner = fence(in: dir), tui = fence(in: dir)
        let a = try runner.begin(.play, owner: "runner")
        _ = try tui.begin(.routeChange, owner: "tui")
        var played = 0
        XCTAssertEqual(try runner.playIfCurrent(a) { played += 1; return 1 }, .invalidated)
        XCTAssertEqual(played, 0)
    }

    /// The rest of the plan's token (generation, index, current track, state) is
    /// the caller's `alsoCurrent`, checked inside the same lock span.
    func testTheCallersOwnChecksRunInsideTheLockAndCanInvalidate() throws {
        let dir = tempDir()
        let f = fence(in: dir)
        let a = try f.begin(.play, owner: "tui")
        var freeInside: Bool?
        var played = 0
        XCTAssertEqual(try f.playIfCurrent(a, alsoCurrent: {
            freeInside = OutputLockTestSupport.isFree(dir + "/output.lock"); return false
        }) { played += 1; return 1 }, .invalidated)
        XCTAssertEqual(freeInside, false, "alsoCurrent ran outside the lock")
        XCTAssertEqual(played, 0)
        XCTAssertEqual(try f.playIfCurrent(a, alsoCurrent: { true }) { played += 1; return 1 }, .played(1))
        XCTAssertEqual(played, 1)
    }

    /// Callers already inside the output lock use the `HoldingLock` forms: the
    /// plain ones would re-enter it.
    func testTheHoldingLockFormsWorkInsideTheOutputLock() throws {
        let dir = tempDir()
        let f = fence(in: dir)
        try f.lock.withLock {
            let a = try f.beginHoldingLock(.play, owner: "cli")
            XCTAssertEqual(try f.playIfCurrentHoldingLock(a) { "ok" }, .played("ok"))
            XCTAssertThrowsError(try f.begin(.play, owner: "cli"), "the plain form re-enters the lock")
        }
    }

    /// A play that throws still releases the lock.
    func testAThrowingPlayReleasesTheLock() throws {
        struct Boom: Error {}
        let dir = tempDir()
        let f = fence(in: dir)
        let a = try f.begin(.play, owner: "tui")
        XCTAssertThrowsError(try f.playIfCurrent(a) { () -> Int in throw Boom() }) { XCTAssertTrue($0 is Boom) }
        XCTAssertTrue(OutputLockTestSupport.isFree(dir + "/output.lock"))
    }
}
