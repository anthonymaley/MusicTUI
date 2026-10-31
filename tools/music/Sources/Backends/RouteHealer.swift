// tools/music/Sources/Backends/RouteHealer.swift
//
// Evidence-ordered heal ladder (spec §Heal ladder). Dropped with evidence:
// re-issuing `set selected` (no-op against a live broken state), list-writing
// the same device (no-op, zero churn), UI-scripting the popover (macOS 26
// chrome is AX-invisible). Tier 1 is the programmatic equivalent of the
// user's manual popover fix; tier 2 adds a transport cycle (UNVERIFIED in
// the spike — validated by scripts/airplay-live-probe.sh before reliance).
import Foundation

/// The slice of AppleScriptBackend that RouteHealer drives — a seam so the tier
/// escalation ladder can be unit-tested without spawning osascript.
/// Synchronous, because the healer is: a blocking call through `syncRun`
/// would wait on Swift's cooperative pool for each script.
protocol MusicScripting {
    func runMusicBlocking(_ script: String, timeout: TimeInterval) throws -> String
}

extension AppleScriptBackend: MusicScripting {}

struct RouteHealer {
    struct Outcome {
        let healed: Bool
        /// 1/2 = tier that healed; 3 = honest failure.
        let tierUsed: Int
        /// The tier-3 message when healed == false.
        let failure: String?
    }

    let backend: MusicScripting
    let verifier: RouteVerifier
    /// Teardown wait between the away and back list-writes. Injectable so tests
    /// don't sleep; production uses the real 1.5s HomePod teardown beat.
    var delay: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    /// Post-reroute verify budget. Injectable so tests can bound the poll loop.
    var verifyTimeout: TimeInterval = 5.0

    /// Heal a target whose establishment verify failed. `groupNames` is the
    /// FULL intended output set (heals must not shrink a multi-speaker group);
    /// `computerName` is the local device (kind == "computer").
    /// Mid-play only — callers guarantee playback is running (routing issued
    /// while paused is untrusted by design; spec §Ordering rule).
    func heal(target: String, ip: String, groupNames: [String], computerName: String,
              scriptingClaims: String) -> Outcome {
        // Tier 1: away-and-back list-write. Routing stays its own osascript
        // call (parameter-error-50 rule).
        switch runTier(away: [computerName], back: groupNames, ip: ip, pauseBracket: false) {
        case .verified: return Outcome(healed: true, tierUsed: 1, failure: nil)
        case .unknown(let reason): return Self.notChecked(target, tier: 1, reason: reason)
        case .failed: break
        }
        // Tier 2: same, bracketed by a transport cycle. Reached only on a
        // real negative from tier 1 — an unreadable table never escalates to
        // a pause/play (Codex 2026-10-31).
        switch runTier(away: [computerName], back: groupNames, ip: ip, pauseBracket: true) {
        case .verified: return Outcome(healed: true, tierUsed: 2, failure: nil)
        case .unknown(let reason): return Self.notChecked(target, tier: 2, reason: reason)
        case .failed: break
        }
        // The network field carries the actual post-heal fingerprint, not a
        // second copy of the summary line (it used to interpolate `evidence`
        // in both slots).
        let networkReading = (try? verifier.steadyState(ip: ip))?.evidence ?? "no readable connections"
        return Outcome(healed: false, tierUsed: 3,
                       failure: Self.honestFailureMessage(
                           speaker: target, ip: ip,
                           evidence: "no session traffic after 2 heal attempts",
                           networkReading: networkReading,
                           scriptingClaims: scriptingClaims))
    }

    enum TierResult { case verified, failed, unknown(String) }

    static func notChecked(_ target: String, tier: Int, reason: String) -> Outcome {
        Outcome(healed: false, tierUsed: tier,
                failure: "· \(target): route not checked after heal step \(tier) — \(reason). Stopped there.")
    }

    private func runTier(away: [String], back: [String], ip: String, pauseBracket: Bool) -> TierResult {
        func listWrite(_ names: [String]) -> Bool {
            let list = names
                .map { "AirPlay device \"\(escapeAppleScriptString($0))\"" }
                .joined(separator: ", ")
            do {
                _ = try backend.runMusicBlocking("set current AirPlay devices to {\(list)}", timeout: 45)
                return true
            } catch {
                verbose("heal: list-write to {\(names.joined(separator: ", "))} failed: \(error.localizedDescription)")
                return false
            }
        }
        // No baseline = nothing to compare against: stop BEFORE any write.
        let baseline: Set<TCPConnection>
        do { baseline = try verifier.snapshot(ip: ip) } catch {
            verbose("heal: baseline snapshot for \(ip) failed — not rerouting")
            return .unknown(error.localizedDescription)
        }
        if pauseBracket { _ = try? backend.runMusicBlocking("pause", timeout: 45) }
        guard listWrite(away) else { return .failed }
        // HomePods need a beat to tear down; 1.5s matches resetAirPlaySpeakers.
        delay(1.5)
        // The group is now away on the Mac: restoring it comes first. One
        // bounded retry, then stop and say so — never escalate from here.
        if !listWrite(back) {
            delay(1.5)
            guard listWrite(back) else {
                return .unknown("couldn't route back to \(back.joined(separator: ", ")); the Mac may be the only output — run: music speaker only \(back.first ?? "")")
            }
        }
        if pauseBracket {
            do { _ = try backend.runMusicBlocking("play", timeout: 45) }
            catch { verbose("heal: play after tier-2 reroute failed: \(error.localizedDescription)") }
        }
        do {
            return try verifier.verifyEstablishment(ip: ip, baseline: baseline, timeout: verifyTimeout).verified
                ? .verified : .failed
        } catch {
            verbose("heal: post-reroute verify errored: \(error.localizedDescription)")
            return .unknown(error.localizedDescription)
        }
    }

    static func honestFailureMessage(speaker: String, ip: String,
                                     evidence: String, networkReading: String,
                                     scriptingClaims: String) -> String {
        """
        ✗ Route to \(speaker) NOT verified: \(evidence).
          Manual fix that works: click the AirPlay icon in Music, deselect and reselect \(speaker).
          (network: \(networkReading) [\(ip)] · scripting claims: \(scriptingClaims))
        """
    }
}

/// Shared post-play verification pass (CLI play path, speaker commands, TUI).
/// `baselines`/`ips` are captured BEFORE routing. Returns printable lines.
func verifyAndHealRoutes(speakers: [String], backend: AppleScriptBackend,
                         baselines: [String: Set<TCPConnection>],
                         ips: [String: String],
                         verifier: RouteVerifier = RouteVerifier()) -> [String] {
    let devices = (try? fetchSpeakerDevices()) ?? []
    let computerName = devices.first { ($0["kind"] as? String) == "computer" }?["name"] as? String
    return verifyAndHealRoutes(speakers: speakers, scripting: backend, computerName: computerName,
                               baselines: baselines, ips: ips, verifier: verifier,
                               claims: { readScriptingClaims(for: $0, backend: backend) })
}

/// The pass itself, with its effects injectable. Phase 1 checks every
/// speaker; phase 2 heals only when NO speaker's route is unknown, because a
/// heal moves the whole group away and back and would tear down a speaker
/// nobody could check (Codex 2026-10-31).
func verifyAndHealRoutes(speakers: [String], scripting: MusicScripting, computerName: String?,
                         baselines: [String: Set<TCPConnection>], ips: [String: String],
                         verifier: RouteVerifier, claims: (String) -> String,
                         healer customHealer: RouteHealer? = nil) -> [String] {
    var lines: [String] = []
    var failed: [(speaker: String, ip: String, verdict: RouteVerdict)] = []
    var unknown: [String] = []
    for speaker in speakers {
        // The Mac's own output is local — there is no AirPlay session to
        // verify or heal (live probe: verifying it burns both heal tiers and
        // prints a false failure).
        if speaker == computerName {
            lines.append("· \(speaker): local output — nothing to verify.")
            continue
        }
        guard let ip = ips[speaker] else {
            lines.append("· \(speaker): could not resolve IP via Bonjour — routed but unverified.")
            unknown.append(speaker)
            continue
        }
        // No pre-route baseline (the table couldn't be read then): sockets
        // already present could later pass for new ones, so no verdict.
        guard let baseline = baselines[speaker] else {
            lines.append("· \(speaker): route not checked — no reading from before the route change.")
            unknown.append(speaker)
            continue
        }
        // check(): fast path for an already-established route, then the delta
        // poll. Only `.failed` is evidence of a broken route.
        switch verifier.check(ip: ip, baseline: baseline) {
        case .verified(let evidence):
            lines.append("✓ \(speaker) verified (\(evidence))")
        case .notChecked(let reason):
            lines.append("· \(speaker): route not checked — \(reason).")
            unknown.append(speaker)
        case .failed(let verdict):
            failed.append((speaker, ip, verdict))
        }
    }
    let manual = "Manual fix: click the AirPlay icon in Music, deselect and reselect"
    for f in failed {
        // A heal reroutes every speaker in the group; never do that while a
        // member's route is unknown.
        if !unknown.isEmpty {
            lines.append("✗ \(f.speaker) NOT verified (\(f.verdict.evidence)) — not healed automatically: \(unknown.joined(separator: ", ")) couldn't be checked, and a heal moves the whole group. \(manual) \(f.speaker).")
            continue
        }
        // No computer device identified (Music scripting degraded) — healing
        // needs a real away-target; say so instead of attempting a heal
        // against a bogus device name.
        guard let computerName else {
            lines.append("✗ \(f.speaker) NOT verified (\(f.verdict.evidence)) — cannot heal: couldn't identify the computer device. \(manual) \(f.speaker).")
            continue
        }
        let healer = customHealer ?? RouteHealer(backend: scripting, verifier: verifier)
        // Advisory context for the failure path: what the (lying) scripting
        // layer claims right now.
        let scriptingClaims = claims(f.speaker)
        let outcome = withStatus("Healing \(f.speaker) route...") {
            healer.heal(target: f.speaker, ip: f.ip, groupNames: speakers,
                        computerName: computerName, scriptingClaims: scriptingClaims)
        }
        if outcome.healed {
            lines.append("✓ \(f.speaker) verified after heal (tier \(outcome.tierUsed))")
        } else {
            lines.append(outcome.failure ?? "✗ \(f.speaker) NOT verified")
        }
    }
    return lines
}

/// The (advisory, often-lying) scripting claims for a device — used only as
/// failure-path context in heal messages. Shared by the verify pass and wake.
func readScriptingClaims(for speaker: String, backend: AppleScriptBackend) -> String {
    (try? backend.runMusicBlocking("""
            get "selected=" & (selected of AirPlay device "\(escapeAppleScriptString(speaker))" as text) & \
            " active=" & (active of AirPlay device "\(escapeAppleScriptString(speaker))" as text)
        """))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unreadable"
}
