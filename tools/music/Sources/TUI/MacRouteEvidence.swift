// tools/music/Sources/TUI/MacRouteEvidence.swift
import Foundation

// The evidence line of the Mac DAC route (mac-route-plan.md, step P6; M4's start
// lines and M5's warning). It says what is actually playing and why, from the
// answers a transition received, and never claims "lossless" or any rate it has
// no evidence for. The texts mirror SpanDAC's own classifier; reasoning stays in
// SpanDAC, this file only renders what the answers and the status carry.
//
// Pure value work plus one lock-guarded holder (`MacRouteEvidence`). No sockets,
// no AppleScript: the status read is a seam `MacRoutePlayer` owns.

/// The words. The codec is "codec unknown" until SpanDAC says otherwise: no
/// answer or status field carries one today.
enum MacRouteEvidenceText {
    static let rateUnknown = "rate unknown"
    static let codecUnknown = "codec unknown"
    static let mayChange = "may change"
    static let switchUnconfirmed = "DAC rate switch unconfirmed"
    static let nextSongSetsIt = "the next song sets it"
    static let notRestored = "rate won't be restored"
    static let pausedToSwitch = "paused to switch the DAC rate, press play"

    static func ownRate(_ hz: Int) -> String { "\(formatSampleRate(hz)) \u{00B7} own rate" }
    static func converted(to hz: Int?) -> String {
        hz.map { "converted to \(formatSampleRate($0)): DAC limit" } ?? "converted: DAC limit"
    }
    static func unconfirmed(song: Int?, dac: Int?) -> String {
        guard let song, let dac else { return switchUnconfirmed }
        return "\(formatSampleRate(song)) song, DAC at \(formatSampleRate(dac)): \(switchUnconfirmed)"
    }
    static func dacRateUnknown(_ hz: Int?) -> String {
        hz.map { "\(formatSampleRate($0)) \u{00B7} DAC rate unknown" } ?? rateUnknown
    }
}

/// M5's late switch, said on the line while the song plays. `moved` (when its
/// `seq` is above the baseline) gives the cause; without it the rate still moved.
func macRouteLateSwitchText(baseline: Int, status: SourceRateFollowStatus) -> (said: String, advice: String)? {
    guard SourceRateFollow.warnsOfRateChange(baseline: baseline, status: status) else { return nil }
    let to = (status.moved?.toHz ?? status.dacRateHz).map { " to \(formatSampleRate($0))" } ?? ""
    if let moved = status.moved, moved.seq > baseline {
        switch moved.cause {
        case .lateSwitch: return ("late switch\(to)", MacRouteEvidenceText.nextSongSetsIt)
        case .outside: return ("DAC rate changed\(to) outside MusicTUI", MacRouteEvidenceText.nextSongSetsIt)
        }
    }
    return ("DAC rate changed\(to)", MacRouteEvidenceText.nextSongSetsIt)
}

private extension RateCorrectionStop {
    var isLockUnavailable: Bool { if case .lockUnavailable = self { return true } else { return false } }
}

/// The line for one played transition, or nil when it has nothing to say (a
/// station or a resume: nothing was converted, the Radio line stands).
func macRouteEvidenceText(for played: RateTransitionPlayed, status: SourceRateFollowStatus? = nil) -> String? {
    var parts: [String] = []
    var answer: SourceRateAnswer?
    if case .answered(let a) = played.rateOutcome { answer = a }
    if case .unsettled(let last) = played.rateOutcome { answer = last }
    // A correction that ran: its own answer decides the start line.
    var startLine = played.startLine
    if case .resumed(_, let corrected) = played.correction {
        startLine = SourceRateStartLine.line(for: corrected)
        if case .answered(let a) = corrected { answer = a }
        if case .unsettled(let last) = corrected { answer = last }
    }
    let songHz = answer?.targetHz ?? played.delivered?.sampleRateHz
    let dacHz = answer?.dacRateHz

    var rate: String?
    switch startLine {
    case .ownRate, .ownRatePriorPending:
        rate = songHz.map(MacRouteEvidenceText.ownRate) ?? MacRouteEvidenceText.rateUnknown
    case .dacLimit:
        rate = MacRouteEvidenceText.converted(to: answer?.dacRateHz ?? dacHz)
    case .unknownRate, .unavailable:
        rate = MacRouteEvidenceText.rateUnknown
    case .unconfirmed, .regressed:
        rate = MacRouteEvidenceText.unconfirmed(song: songHz, dac: answer?.dacRateHz ?? dacHz)
    case .noDAC:
        rate = MacRouteEvidenceText.dacRateUnknown(songHz)
    case .notOffered:
        rate = sourceRateFollowUpdateSentence
    case .quiet:
        rate = nil
    }
    // The identity-checked read is evidence: when SpanDAC says what Music
    // delivered, that outranks the prediction.
    // After a correction that resumed the song, the SECOND confirm is the read of
    // the corrected song; the first one described the song before the switch.
    if case .answered(let confirmed)? = played.confirmAfterCorrection ?? played.confirm {
        switch confirmed.outcome {
        case .ownRate: if let hz = played.delivered?.sampleRateHz { rate = MacRouteEvidenceText.ownRate(hz) }
        // `converted to` names the rate the DAC is AT (the answer's own field),
        // never the song's delivered rate; with none in the answer, no rate.
        case .converted: rate = MacRouteEvidenceText.converted(to: confirmed.dacRateHz)
        case .deliveredUnknown: rate = MacRouteEvidenceText.dacRateUnknown(songHz)
        default: break
        }
    }
    // The corrected song's own read still says the DAC is not at its rate: the
    // switch did not take, whatever the correction's answer predicted.
    if case .answered(let after)? = played.confirmAfterCorrection, after.outcome == .correct {
        rate = MacRouteEvidenceText.unconfirmed(song: after.targetHz ?? played.delivered?.sampleRateHz,
                                                dac: after.dacRateHz)
    }
    guard let rate else { return nil }
    parts.append(rate)
    if case .notOffered = startLine { return rate }
    // This DAC's rate will not be put back: said right after the rate, so a narrow
    // screen (which cuts the end) drops everything else before it.
    if macRouteRateNotRestorable(played, status: status) { parts.append(MacRouteEvidenceText.notRestored) }
    // Most important first: a narrow screen cuts the end.
    if answer?.priorUnresolved == true || playedConfirmPriorUnresolved(played) {
        parts.append(MacRouteEvidenceText.mayChange)
    }
    // The lock-unavailable sentence is P4's: not repeated here.
    if case .stopped(let stop, _) = played.correction, stop.leavesOurPause, !stop.isLockUnavailable {
        parts.append(MacRouteEvidenceText.pausedToSwitch)
    }
    var advice: String?
    if let baseline = played.baseline, let status,
       let late = macRouteLateSwitchText(baseline: baseline, status: status) {
        parts.append(late.said); advice = late.advice
    }
    parts.append(MacRouteEvidenceText.codecUnknown)
    if let advice { parts.append(advice) }
    return parts.joined(separator: " \u{00B7} ")
}

/// SpanDAC said (in the status or in any answer of this transition) that it holds
/// no restore record for the DAC. Missing is unknown, and unknown says nothing.
private func macRouteRateNotRestorable(_ played: RateTransitionPlayed, status: SourceRateFollowStatus?) -> Bool {
    if status?.restorable == false { return true }
    var outcomes: [SourceRateOutcome?] = [played.rateOutcome, played.confirm, played.confirmAfterCorrection]
    if case .resumed(_, let corrected) = played.correction { outcomes.append(corrected) }
    for outcome in outcomes {
        switch outcome {
        case .answered(let a)?: if a.restorable == false { return true }
        case .unsettled(let last)?: if last?.restorable == false { return true }
        default: break
        }
    }
    return false
}

private func playedConfirmPriorUnresolved(_ played: RateTransitionPlayed) -> Bool {
    if case .answered(let a)? = played.confirm { return a.priorUnresolved }
    return false
}

/// The latest transition's line for this process. Written by the transition's
/// thread and the status read, read by the render threads.
final class MacRouteEvidence {
    private let lock = NSLock()
    private var played: RateTransitionPlayed?
    private var status: SourceRateFollowStatus?
    private var unfollowed = false

    /// Replaces the evidence on a played result; any other result leaves it (a
    /// newer command that took over records its own).
    func record(_ result: RateTransitionResult) {
        lock.lock(); defer { lock.unlock() }
        switch result {
        case .played(let p): played = p; status = nil; unfollowed = false
        case .playedUnfollowed: played = nil; status = nil; unfollowed = true
        default: break
        }
    }

    /// A later read of the same song (`RateAwareTransition.recheck`): replaces the
    /// evidence only while it is still that song's; a newer start has its own.
    func replace(_ updated: RateTransitionPlayed) {
        lock.lock(); defer { lock.unlock() }
        guard let current = played, current.token == updated.token else { return }
        played = updated
    }

    func noteStatus(_ status: SourceRateFollowStatus?) {
        lock.lock(); self.status = status; lock.unlock()
    }

    func clear() {
        lock.lock(); played = nil; status = nil; unfollowed = false; lock.unlock()
    }

    var line: String? {
        lock.lock(); defer { lock.unlock() }
        if unfollowed { return "\(MacRouteEvidenceText.rateUnknown) \u{00B7} \(MacRouteEvidenceText.codecUnknown)" }
        guard let played else { return nil }
        return macRouteEvidenceText(for: played, status: status)
    }
}
