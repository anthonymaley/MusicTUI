// tools/music/Sources/TUI/Shell/PlayConfirmation.swift
//
// RED-PHASE STUB (honest "Playing", 2026-11-01): the API the tests in
// HonestPlayingTests.swift name, with today's behaviour (nothing is read,
// nothing is held, nothing is posted), so the tests compile and fail on what
// the code does now. The next commit replaces it.
import Foundation

struct PlayerIdentityReading: Equatable {
    let state: String
    let persistentID: String?
}

let playerIdentityReadScript = ""

func parsePlayerIdentityReading(_ raw: String) -> PlayerIdentityReading? { nil }

func readPlayerIdentity(backend: AppleScriptBackend, timeout: TimeInterval = 2) -> PlayerIdentityReading? { nil }

func playNotStartedWarning(_ title: String) -> String {
    "Play was requested, but Music hasn't started '\(title)' yet. If nothing plays, quitting and reopening Music fixed this before."
}

struct PlayConfirmFence: Equatable {
    let epoch: Int
    let dataEpoch: Int
    let playSerial: Int

    static let still = PlayConfirmFence(epoch: 0, dataEpoch: 0, playSerial: 0)
}

final class PlayConfirmer {
    struct Ticket: Equatable { let serial: Int }

    struct Timing: Equatable {
        var interval: TimeInterval = 0.25
        var window: TimeInterval = 1.5
    }

    init(read: @escaping () -> PlayerIdentityReading?,
         post: @escaping (String) -> Void,
         fence: @escaping () -> PlayConfirmFence = { .still },
         timing: Timing = Timing(),
         now: @escaping () -> Date = Date.init,
         sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
         schedule: @escaping (@escaping () -> Void) -> Void = {
             DispatchQueue.global(qos: .userInitiated).async(execute: $0)
         }) {}

    func request() -> Ticket { Ticket(serial: 0) }
    func abandon(_ ticket: Ticket) {}
    func confirm(_ ticket: Ticket, expected: String?, title: String) {}
    func invalidate() {}
    var holdsAutoAdvance: Bool { false }
    func observeCurrentTrack() {}
    func observe(currentPersistentID: String?) {}
}
