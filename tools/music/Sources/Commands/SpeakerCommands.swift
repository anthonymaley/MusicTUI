import ArgumentParser
import Foundation

// MARK: - Smart parser (tested in SmartParserTests)

enum SpeakerAction: Equatable {
    case interactive
    case list
    case add(name: String)
    case addWithVolume(name: String, volume: Int)
    case remove(name: String)
    case exclusive(name: String)
    case indices([Int])
    case wake(name: String?)
    case verify(name: String?)
}

struct SpeakerParser {
    static func parse(_ args: [String]) -> SpeakerAction {
        guard !args.isEmpty else { return .interactive }
        if args.count == 1 && args[0].lowercased() == "list" { return .list }
        if args.count >= 1 && args[0].lowercased() == "wake" {
            let name = args.count > 1 ? args.dropFirst().joined(separator: " ") : nil
            return .wake(name: name)
        }
        if args.count >= 1 && args[0].lowercased() == "verify" {
            let name = args.count > 1 ? args.dropFirst().joined(separator: " ") : nil
            return .verify(name: name)
        }
        let ints = args.compactMap { Int($0) }
        if ints.count == args.count { return .indices(ints) }
        let lastArg = args.last!.lowercased()
        if lastArg == "stop" {
            return .remove(name: args.dropLast().joined(separator: " "))
        }
        if lastArg == "only" {
            return .exclusive(name: args.dropLast().joined(separator: " "))
        }
        if let vol = Int(lastArg), (0...100).contains(vol), args.count >= 2 {
            return .addWithVolume(name: args.dropLast().joined(separator: " "), volume: vol)
        }
        return .add(name: args.joined(separator: " "))
    }
}

// MARK: - Main speaker command

struct Speaker: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage AirPlay speakers.",
        subcommands: [SpeakerSmart.self, SpeakerList.self, SpeakerSet.self, SpeakerAdd.self, SpeakerRemove.self, SpeakerStop.self],
        defaultSubcommand: SpeakerSmart.self
    )
}

struct SpeakerSmart: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "smart", abstract: "Smart speaker control.", shouldDisplay: false)
    @Argument(help: "Speaker name, index, volume, or keyword (stop/only/list/wake/verify)") var args: [String] = []
    @Flag(name: .long, help: "Output JSON") var json = false
    @Flag(name: .shortAndLong, help: "Show diagnostic output") var verbose = false

    func run() throws {
        try refuseInBridge(.airplayRoute, json: json)
        Music.verbose = verbose
        Music.isJSON = json
        try runSpeakerSmart(args: args, json: json)
    }
}

// MARK: - Shared logic (callable without ArgumentParser)

/// Slice 3 S8 (R1): whether a speaker action can reach route healing, which
/// pauses and then plays (`RouteHealer.swift:81-87`), and so must run inside
/// the output lock where a TUI Output switch cannot straddle it. `list`,
/// `verify` and the interactive picker never heal, play or pause (the picker
/// only sets selection and volume), so they take no lock.
func speakerActionRequiresOutputLock(_ action: SpeakerAction) -> Bool {
    switch action {
    case .add, .addWithVolume, .remove, .exclusive, .indices, .wake:
        return true
    case .list, .verify, .interactive:
        return false
    }
}

/// Every speaker command's entry, with the live values: the output lock
/// expecting Music.app (the Bridge gate has already run in each `run()`), and
/// the shipped body.
func runSpeakerSmart(args: [String], json: Bool) throws {
    try runSpeakerSmart(args: args, json: json,
                        guard: { body in try withCLIOutputLock(expecting: .musicApp, json: json, env: .live(), body) },
                        execute: executeSpeakerAction)
}

/// The command-owned path (S8, R1): parse, classify, and run `execute` inside
/// `guard` for every action that can reach route healing, or directly for the
/// read-only ones. Tests pass the real `withCLIOutputLock` on a temp store and
/// a fake `execute` standing in for the healer.
func runSpeakerSmart(args: [String], json: Bool,
                     guard lockGuard: (() throws -> Void) throws -> Void,
                     execute: (SpeakerAction, Bool) throws -> Void) throws {
    let action = SpeakerParser.parse(args)
    if speakerActionRequiresOutputLock(action) {
        try withoutActuallyEscaping(execute) { execute in
            try lockGuard { try execute(action, json) }
        }
    } else {
        try execute(action, json)
    }
}

/// The shipped per-action body, moved verbatim from `runSpeakerSmart` (S8).
func executeSpeakerAction(_ action: SpeakerAction, json: Bool) throws {
    let backend = AppleScriptBackend()

    switch action {
    case .interactive:
        guard isTTY() else {
            try listSpeakers(json: json)
            return
        }
        try runSpeakerTUI()

    case .list:
        try listSpeakers(json: json)

    case .add(let name):
        let resolved = try resolveSpeakerName(name, backend: backend)
        let playing = playerIsPlaying(backend: backend)
        let capture = playing ? captureRouteBaseline(for: resolved) : (ip: nil, baseline: nil)
        _ = try backend.runMusicBlocking("set selected of AirPlay device \"\(escapeAppleScriptString(resolved))\" to true")
        print("Added \(resolved).")
        if playing {
            verifyRoute(speaker: resolved, backend: backend, baseline: capture.baseline, ip: capture.ip)
        } else {
            print("Route set; will verify on next play.")
        }

    case .addWithVolume(let name, let volume):
        let resolved = try resolveSpeakerName(name, backend: backend)
        let playing = playerIsPlaying(backend: backend)
        let capture = playing ? captureRouteBaseline(for: resolved) : (ip: nil, baseline: nil)
        _ = try backend.runMusicBlocking("set selected of AirPlay device \"\(escapeAppleScriptString(resolved))\" to true")
        _ = try backend.runMusicBlocking("set sound volume of AirPlay device \"\(escapeAppleScriptString(resolved))\" to \(volume)")
        print("Added \(resolved) [\(volume)].")
        if playing {
            verifyRoute(speaker: resolved, backend: backend, baseline: capture.baseline, ip: capture.ip)
        } else {
            print("Route set; will verify on next play.")
        }

    case .remove(let name):
        let resolved = try resolveSpeakerName(name, backend: backend)
        _ = try backend.runMusicBlocking("set selected of AirPlay device \"\(escapeAppleScriptString(resolved))\" to false")
        print("Removed \(resolved).")

    case .exclusive(let name):
        let resolved = try resolveSpeakerName(name, backend: backend)
        let playing = playerIsPlaying(backend: backend)
        let capture = playing ? captureRouteBaseline(for: resolved) : (ip: nil, baseline: nil)
        // Select the target FIRST: the old deselect-all-then-select could end
        // with NO outputs at all if the target failed after the teardown. Also
        // per-device try — one unreachable device must not abort the rest (an
        // AppleScript repeat dies on the first error otherwise).
        _ = try backend.runMusicBlocking("set selected of AirPlay device \"\(escapeAppleScriptString(resolved))\" to true")
        _ = try backend.runMusicBlocking("""
                repeat with d in (every AirPlay device)
                    try
                        if name of d is not "\(escapeAppleScriptString(resolved))" and selected of d then
                            set selected of d to false
                        end if
                    end try
                end repeat
            """)
        print("Switched to \(resolved) only.")
        if playing {
            verifyRoute(speaker: resolved, backend: backend, baseline: capture.baseline, ip: capture.ip)
        } else {
            print("Route set; will verify on next play.")
        }

    case .indices(let idxs):
        let cache = ResultCache()
        // Quick-picker adds are verified while playing, same as every other add
        // path — this used to select silently. verifyRoute skips the computer
        // row (local output) on its own.
        let playing = playerIsPlaying(backend: backend)
        for idx in idxs {
            let speaker = try cache.lookupSpeaker(index: idx)
            let capture = playing ? captureRouteBaseline(for: speaker.name) : (ip: nil, baseline: nil)
            _ = try backend.runMusicBlocking("set selected of AirPlay device \"\(escapeAppleScriptString(speaker.name))\" to true")
            print("Added \(speaker.name).")
            if playing {
                verifyRoute(speaker: speaker.name, backend: backend, baseline: capture.baseline, ip: capture.ip)
            }
        }

    case .wake(let name):
        if let name = name {
            // Wake a specific speaker: select it, then reset to establish a clean connection
            let resolved = try resolveSpeakerName(name, backend: backend)
            do {
                _ = try backend.runMusicBlocking("set selected of AirPlay device \"\(escapeAppleScriptString(resolved))\" to true")
            } catch {
                // A sleeping device erroring on first select is the very case
                // wake exists for — say so instead of dumping AppleScript noise.
                throw AppleScriptBackend.ScriptError.speakerUnavailable(resolved)
            }
        }
        // Verify first — only reset what the network says is actually broken.
        // (Blind reset tore down healthy routes too.)
        let verifier = RouteVerifier()
        // A failed read is not "no speakers": resetting from it reset every
        // active speaker unobserved (Codex 2026-10-31).
        guard let devices = try? fetchSpeakerDevices() else {
            print("Couldn't read the speaker list — nothing reset.")
            return
        }
        let routed = devices
            .filter { ($0["selected"] as? Bool == true) && ($0["kind"] as? String != "computer") }
            .compactMap { $0["name"] as? String }
        // Only a real negative is reset. A speaker whose address won't resolve
        // or whose connection read fails is unknown and left alone: resetting
        // on a guess tore down working routes (2026-10-31).
        let triage = triageWakeTargets(routed, verifier: verifier)
        for speaker in triage.verified { print("✓ \(speaker) verified — leaving it alone.") }
        for (speaker, reason) in triage.unknown {
            print("· \(speaker): route not checked (\(reason)) — left alone. If it is silent: click the AirPlay icon in Music, deselect and reselect it.")
        }
        let broken = triage.broken
        if routed.isEmpty {
            print("No AirPlay speakers are routed. Nothing to reset.")
            return
        }
        if broken.isEmpty {
            if triage.unknown.isEmpty { print("All routed speakers verified. Nothing to reset.") }
            return
        }
        // Automatic healing/resetting is OFF (Anthony 2026-10-31, 3.24.2):
        // it moves every routed speaker and can tear down working ones. Report
        // the broken ones with the manual fix instead.
        for speaker in broken.sorted() {
            print("✗ \(speaker) NOT verified. Manual fix: click the AirPlay icon in Music, deselect and reselect \(speaker).")
        }

    case .verify(let name):
        try runSpeakerVerify(name: name, backend: backend, json: json)
    }
}

/// Sort routed speakers for `speaker wake`: verified, broken (a readable
/// connection table showed no session), or unknown (no address, or the read
/// failed). Only `broken` may be reset or healed.
func triageWakeTargets(_ routed: [String], verifier: RouteVerifier)
    -> (verified: [String], broken: Set<String>, unknown: [(String, String)]) {
    var verified: [String] = [], broken: Set<String> = [], unknown: [(String, String)] = []
    for speaker in routed {
        guard let ip = verifier.resolver.resolveIP(forSpeaker: speaker) else {
            unknown.append((speaker, "could not resolve its address"))
            continue
        }
        do {
            if try verifier.steadyState(ip: ip).verified { verified.append(speaker) } else { broken.insert(speaker) }
        } catch {
            unknown.append((speaker, error.localizedDescription))
        }
    }
    return (verified, broken, unknown)
}

/// Cheap shared player-state read for the routing cases.
func playerIsPlaying(backend: AppleScriptBackend) -> Bool {
    (((try? backend.runMusicBlocking("player state as text")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) == "playing"
}

/// Pre-route capture — only worth paying for while playing (the Bonjour
/// resolve can cost seconds; a paused add defers verification anyway).
func captureRouteBaseline(for speaker: String) -> (ip: String?, baseline: Set<TCPConnection>?) {
    let verifier = RouteVerifier()
    let ip = verifier.resolver.resolveIP(forSpeaker: speaker)
    return (ip, ip.flatMap { try? verifier.snapshot(ip: $0) })
}

/// Post-route verification for speaker commands, mid-play only (paused
/// routing can't be network-verified and is the spike-observed corruption
/// trigger; the play path re-verifies).
func verifyRoute(speaker: String, backend: AppleScriptBackend,
                 baseline: Set<TCPConnection>?, ip: String?) {
    guard let ip = ip, let baseline = baseline else {
        print("· \(speaker): could not resolve IP via Bonjour — routed but unverified.")
        return
    }
    for line in verifyAndHealRoutes(speakers: [speaker], backend: backend,
                                    baselines: [speaker: baseline], ips: [speaker: ip]) {
        print(line)
    }
}

/// Read-only network-truth verdict for a routed speaker. No name = verify
/// every device the scripting layer claims is selected (advisory claims are
/// printed alongside — they can lie; the network verdict is the answer).
func runSpeakerVerify(name: String?, backend: AppleScriptBackend, json: Bool) throws {
    let devices = try fetchSpeakerDevices()
    let targets: [String]
    if let name = name {
        targets = [try resolveSpeakerName(name, backend: backend)]
    } else {
        targets = devices
            .filter { ($0["selected"] as? Bool == true) && ($0["kind"] as? String != "computer") }
            .compactMap { $0["name"] as? String }
        guard !targets.isEmpty else {
            print("No non-local speakers are selected. Nothing to verify.")
            return
        }
    }

    let verifier = RouteVerifier()
    var results: [[String: Any]] = []
    for target in targets {
        let claimed = devices.first { ($0["name"] as? String) == target }?["selected"] as? Bool ?? false
        // The Mac's own output self-resolves via Bonjour and steadyState reports
        // it ✗ — there is no AirPlay session. An explicitly-named computer target
        // gets an honest "nothing to verify" instead (the no-name path already
        // filters it out).
        if devices.first(where: { ($0["name"] as? String) == target })?["kind"] as? String == "computer" {
            results.append(["name": target, "verified": true, "local": true, "ip": "",
                            "evidence": "local output — nothing to verify", "claimedSelected": claimed])
            continue
        }
        guard let ip = verifier.resolver.resolveIP(forSpeaker: target) else {
            results.append(["name": target, "verified": false, "ip": "",
                            "evidence": "could not resolve IP via Bonjour — cannot verify",
                            "claimedSelected": claimed])
            continue
        }
        let verdict: RouteVerdict
        do {
            verdict = try verifier.steadyState(ip: ip)
        } catch {
            // netstat failing is not evidence about the route — degrade this
            // row honestly instead of aborting every target's verdict.
            verdict = RouteVerdict(verified: false,
                                   evidence: "verification errored: \(error.localizedDescription)",
                                   advisory: nil)
        }
        var row: [String: Any] = ["name": target, "verified": verdict.verified, "ip": ip,
                                  "evidence": verdict.evidence, "claimedSelected": claimed]
        if let advisory = verdict.advisory { row["advisory"] = advisory }
        results.append(row)
    }

    if json {
        let output = OutputFormat(mode: .json)
        print(output.render(["results": results]))
        return
    }
    for r in results {
        let mark = (r["local"] as? Bool == true) ? "·" : ((r["verified"] as? Bool == true) ? "✓" : "✗")
        print("\(mark) \(r["name"]!) — \(r["evidence"]!) (scripting claims selected: \(r["claimedSelected"]!))")
        if let advisory = r["advisory"] { print("  \(advisory)") }
    }
}

private func runSpeakerTUI() throws {
    let devices = try fetchSpeakerDevices()
    var volumes = devices.map { $0["volume"] as! Int }
    var items = devices.map {
        MultiSelectItem(label: $0["name"] as! String, sublabel: "vol: \($0["volume"]!)", selected: $0["selected"] as! Bool)
    }

    let backend = AppleScriptBackend()
    // Collect failures and surface them after the picker closes — writing to
    // stderr mid-render would corrupt the live list. Previously `_ = try?` made
    // a failed AirPlay route/volume write invisible (the row still flipped).
    var actionErrors: [String] = []
    let result = runMultiSelectList(title: "AirPlay Speakers", items: &items, onToggle: { idx, selected in
        let name = devices[idx]["name"] as! String
        do {
            _ = try backend.runMusicBlocking("set selected of AirPlay device \"\(escapeAppleScriptString(name))\" to \(selected)")
        } catch {
            actionErrors.append("Couldn't \(selected ? "add" : "remove") \(name): \(error.localizedDescription)")
        }
    }, onAdjust: { idx, delta in
        volumes[idx] = min(100, max(0, volumes[idx] + delta))
        let name = devices[idx]["name"] as! String
        let vol = volumes[idx]
        do {
            _ = try backend.runMusicBlocking("set sound volume of AirPlay device \"\(escapeAppleScriptString(name))\" to \(vol)")
        } catch {
            actionErrors.append("Couldn't set \(name) volume: \(error.localizedDescription)")
        }
        return "vol: \(vol)"
    })

    switch result {
    case .confirmed(let indices):
        let cache = ResultCache()
        let speakerResults = items.enumerated().map { (i, item) in
            SpeakerResult(index: i + 1, name: item.label, selected: indices.contains(i), volume: volumes[i])
        }
        try? cache.writeSpeakers(speakerResults)
        let activeNames = indices.map { items[$0].label }
        print("Active: \(activeNames.joined(separator: ", "))")
    case .cancelled:
        let cache = ResultCache()
        let speakerResults = items.enumerated().map { (i, item) in
            SpeakerResult(index: i + 1, name: item.label, selected: item.selected, volume: volumes[i])
        }
        try? cache.writeSpeakers(speakerResults)
    default:
        break
    }

    for message in actionErrors {
        errorOut("✗ \(message)")
    }
}

/// Field-block separator for the bulk device fetch. Linefeed-joined lists per
/// property, blocks separated by this marker — immune to commas (and `|`) in
/// device names, unlike the old per-row pipe format.
let speakerBlockSeparator = "\n=====\n"

/// Pure parse of the 4-block bulk fetch (names / selected / volumes / kinds).
func parseSpeakerDeviceBlocks(_ raw: String) -> [[String: Any]] {
    parseSpeakerDeviceBlocksChecked(raw) ?? []
}

/// nil means the response was torn or malformed; [] is a successful empty list.
func parseSpeakerDeviceBlocksChecked(_ raw: String) -> [[String: Any]]? {
    let blocks = raw
        .components(separatedBy: speakerBlockSeparator)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard blocks.count == 4 else { return nil }
    if blocks.allSatisfy(\.isEmpty) { return [] }
    let names = blocks[0].components(separatedBy: "\n")
    let sels = blocks[1].components(separatedBy: "\n")
    let vols = blocks[2].components(separatedBy: "\n")
    let kinds = blocks[3].components(separatedBy: "\n")
    guard names.count == sels.count, names.count == vols.count, names.count == kinds.count else { return nil }
    var result: [[String: Any]] = []
    for i in 0..<names.count {
        guard !names[i].isEmpty, ["true", "false"].contains(sels[i]),
              let volume = Int(vols[i]), (0...100).contains(volume), !kinds[i].isEmpty else { return nil }
        result.append([
            "name": names[i],
            "selected": sels[i] == "true",
            "volume": volume,
            "kind": kinds[i]
        ])
    }
    return result
}

/// All AirPlay devices in one osascript with 4 bulk Apple Events — measured 6x
/// faster than the old per-device property loop (0.21s vs 1.23s, 11 devices).
/// Write-through to the speakers cache so name resolution can skip the live
/// round-trip entirely.
func fetchSpeakerDevices() throws -> [[String: Any]] {
    let backend = AppleScriptBackend()
    let result = try backend.runMusicBlocking("""
            \(speakerDeviceReadLines)
            set sep to linefeed & "=====" & linefeed
            return ns & sep & sels & sep & vols & sep & ks
        """, timeout: 20)
    guard let devices = parseSpeakerDeviceBlocksChecked(result) else {
        throw ActionError(message: "Couldn't read the AirPlay speaker list.")
    }
    writeSpeakersCache(devices, to: ResultCache())
    return devices
}

/// The four bulk reads, run inside a Music tell block. Shared by the CLI's
/// `fetchSpeakerDevices` and the Output tab's `fetchOutputTabSpeakerDevices`.
private let speakerDeviceReadLines = """
    set astid to AppleScript's text item delimiters
    set AppleScript's text item delimiters to linefeed
    set ns to (name of every AirPlay device) as text
    set sels to (selected of every AirPlay device) as text
    set vols to (sound volume of every AirPlay device) as text
    set ks to (kind of every AirPlay device) as text
    set AppleScript's text item delimiters to astid
    """

/// Write-through so name resolution can skip the live round-trip. Music's
/// own device volume, as before, whatever the Output tab shows.
private func writeSpeakersCache(_ devices: [[String: Any]], to cache: ResultCache?) {
    guard let cache, !devices.isEmpty else { return }
    let speakerResults = devices.enumerated().map { (i, d) in
        SpeakerResult(index: i + 1, name: d["name"] as! String,
                      selected: d["selected"] as! Bool, volume: d["volume"] as! Int)
    }
    try? cache.writeSpeakers(speakerResults)
}

/// The Output tab's list read: the four bulk device reads plus the macOS
/// output volume, in ONE osascript (no second launch per refresh).
///
/// On the laptop (macOS 27, built-in speakers, 2026-11-01) Music's own
/// `sound volume` for the Mac's device moved and read back with no audible
/// change; the macOS output volume is what you hear. So the row for the Mac's
/// own output (kind "computer") shows and sets that instead.
///
/// `get volume settings` is a Standard Additions command and runs outside the
/// Music tell block, so it is answered here, not sent to Music. Its `output
/// volume` is missing value for an output with no software volume (some DACs,
/// HDMI); that comes back as "missing value". A failing read is caught in the
/// script and answered "unknown", so it never hides the AirPlay list.
func fetchOutputTabSpeakerDevices(backend: AppleScriptBackend = AppleScriptBackend(),
                                  cache: ResultCache? = ResultCache()) throws -> [[String: Any]] {
    let result = try backend.runBlocking("""
        tell application "Music"
            \(speakerDeviceReadLines)
        end tell
        try
            set ov to output volume of (get volume settings)
            if ov is missing value then
                set ovText to "missing value"
            else
                set ovText to ov as text
            end if
        on error
            set ovText to "unknown"
        end try
        set sep to linefeed & "=====" & linefeed
        return ns & sep & sels & sep & vols & sep & ks & sep & ovText
        """, timeout: 20)
    guard let devices = parseOutputTabSpeakerBlocks(result) else {
        throw ActionError(message: "Couldn't read the AirPlay speaker list.")
    }
    writeSpeakersCache(devices, to: cache)
    return devices
}

/// The four device blocks, then a fifth: the macOS output volume. It is put on
/// every "computer" row as `outputVolume`: an Int 0...100, "missing" when the
/// output has no software volume, or "unknown" for anything else (a failed
/// read, a malformed or out-of-range answer). Never dropped: an absent value
/// once let the row fall back to Music's unrelated number. A torn device list
/// is nil, as before.
func parseOutputTabSpeakerBlocks(_ raw: String) -> [[String: Any]]? {
    // An empty fifth block with its trailing newline trimmed still separates.
    let raw = raw.hasSuffix("\n") ? raw : raw + "\n"
    guard let cut = raw.range(of: speakerBlockSeparator, options: .backwards),
          var devices = parseSpeakerDeviceBlocksChecked(String(raw[..<cut.lowerBound])) else { return nil }
    let tail = raw[cut.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    let outputVolume: Any
    if tail == "missing value" {
        outputVolume = "missing"
    } else if let v = Int(tail), (0...100).contains(v) {
        outputVolume = v
    } else {
        outputVolume = "unknown"
    }
    for i in devices.indices where devices[i]["kind"] as? String == "computer" {
        devices[i]["outputVolume"] = outputVolume
    }
    return devices
}

// MARK: - AirPlay speaker reset

struct SpeakerSnapshot {
    let name: String
    let volume: Int
    /// Confirmed back in the group after the reset cycle. The old flow reported
    /// "Reset X" for speakers whose reselect silently failed — X was actually
    /// DROPPED from the group while the output claimed success.
    var reselected: Bool = true
}

/// Reset all active non-local AirPlay speakers: deselect → wait → reselect → restore volumes.
/// Clears ghost connections by forcing the AirPlay stack to fully tear down and rebuild sessions.
/// Returns the speakers that were reset, empty if none needed resetting.
@discardableResult
func resetAirPlaySpeakers(backend: AppleScriptBackend, only: Set<String>? = nil) -> [SpeakerSnapshot] {
    guard let devices = try? fetchSpeakerDevices() else {
        errorOut("✗ Couldn't enumerate AirPlay speakers to reset.")
        verbose("reset: fetchSpeakerDevices failed, skipping")
        return []
    }
    let nonLocal = devices.filter {
        ($0["selected"] as? Bool == true) && ($0["kind"] as? String != "computer")
            && (only == nil || only!.contains($0["name"] as! String))
    }
    guard !nonLocal.isEmpty else { return [] }

    let speakers = nonLocal.map {
        SpeakerSnapshot(name: $0["name"] as! String, volume: $0["volume"] as! Int)
    }
    verbose("resetting AirPlay: \(speakers.map { "\($0.name) [\($0.volume)]" }.joined(separator: ", "))")

    // Deselect all
    for s in speakers {
        verbose("deselecting \(s.name)...")
        do {
            _ = try backend.runMusicBlocking("set selected of AirPlay device \"\(escapeAppleScriptString(s.name))\" to false")
        } catch {
            verbose("deselect failed for \(s.name): \(error.localizedDescription)")
        }
    }

    // Wait for AirPlay stack to fully tear down stale sessions.
    // HomePods need 1-2s after idle/sleep; 1.5s matches human toggle speed.
    verbose("waiting 1.5s for AirPlay teardown...")
    Thread.sleep(forTimeInterval: 1.5)

    // Reselect all
    for s in speakers {
        verbose("reselecting \(s.name)...")
        do {
            _ = try backend.runMusicBlocking("set selected of AirPlay device \"\(escapeAppleScriptString(s.name))\" to true")
        } catch {
            verbose("reselect failed for \(s.name): \(error.localizedDescription)")
        }
    }

    // Restore per-speaker volumes (deselect can reset to default)
    for s in speakers {
        do {
            _ = try backend.runMusicBlocking("set sound volume of AirPlay device \"\(escapeAppleScriptString(s.name))\" to \(s.volume)")
        } catch {
            verbose("volume restore failed for \(s.name): \(error.localizedDescription)")
        }
    }

    // Wait for AirPlay to establish new audio streams
    verbose("waiting 1.5s for AirPlay reconnect...")
    Thread.sleep(forTimeInterval: 1.5)

    // Verify the group actually came back — don't claim success for a speaker
    // whose reselect silently failed.
    let after = try? fetchSpeakerDevices()
    if after == nil {
        errorOut("✗ Couldn't verify AirPlay reset (re-enumeration failed); speakers may not have reconnected.")
    }
    let selectedNow = Set((after ?? []).filter { $0["selected"] as? Bool == true }.compactMap { $0["name"] as? String })
    let outcomes = speakers.map {
        SpeakerSnapshot(name: $0.name, volume: $0.volume, reselected: after == nil || selectedNow.contains($0.name))
    }
    verbose("reset complete: \(outcomes.map { "\($0.name)\($0.reselected ? "" : " (LOST)")" }.joined(separator: ", "))")
    return outcomes
}

/// Deselect→reselect fallback for `wake` when the heal ladder can't run (paused,
/// or a broken speaker with no resolvable IP / no computer device to bounce
/// off). `only == nil` resets every routed speaker.
func resetBroken(_ only: Set<String>?, backend: AppleScriptBackend) {
    let reset = withStatus("Resetting AirPlay speakers...") {
        resetAirPlaySpeakers(backend: backend, only: only)
    }
    if reset.isEmpty {
        print("No active AirPlay speakers to reset.")
    } else {
        for s in reset {
            print(s.reselected
                ? "Reset \(s.name) [\(s.volume)]."
                : "Lost \(s.name) — could not reselect after reset. Try: music speaker \(s.name)")
        }
    }
}

// MARK: - Speaker name resolution (case-insensitive exact > prefix > contains)

/// Pure match against a name list. An empty (or whitespace-only) input matches
/// nothing: hasPrefix("") is true for EVERY string, so a bare `speaker stop` /
/// `speaker only` (or a script's unset $NAME) used to resolve to an arbitrary
/// device and deselect real speakers.
func matchSpeakerName(_ input: String, in names: [String]) -> String? {
    let lower = input.lowercased().trimmingCharacters(in: .whitespaces)
    guard !lower.isEmpty else { return nil }
    if let exact = names.first(where: { $0.lowercased() == lower }) { return exact }
    if let prefix = names.first(where: { $0.lowercased().hasPrefix(lower) }) { return prefix }
    return names.first { $0.lowercased().contains(lower) }
}

/// Resolve user input to a device name. Cache-first: speaker names change
/// ~never, the cache is write-through on every fetch, and skipping the live
/// round-trip removes an osascript spawn from every named speaker/volume
/// command. A cache miss (or no cache) falls back to a live fetch — which
/// also replaces the old comma-split name parse that broke on device names
/// containing commas.
func resolveSpeakerName(_ input: String, backend: AppleScriptBackend) throws -> String {
    if let cached = try? ResultCache().readSpeakers(),
       let match = matchSpeakerName(input, in: cached.map(\.name)) {
        verbose("resolved \"\(input)\" → \"\(match)\" (cache)")
        return match
    }
    let names = try fetchSpeakerDevices().compactMap { $0["name"] as? String }
    verbose("resolving speaker \"\(input)\" against: \(names.joined(separator: ", "))")
    if let match = matchSpeakerName(input, in: names) {
        verbose("resolved \"\(input)\" → \"\(match)\" (live)")
        return match
    }
    throw AppleScriptBackend.ScriptError.speakerNotFound(name: input, available: names)
}

func listSpeakers(json: Bool) throws {
    // fetchSpeakerDevices is the one enumeration (bulk reads + cache write-through);
    // this used to duplicate the whole script inline.
    let devices = try fetchSpeakerDevices()

    if json {
        let output = OutputFormat(mode: .json)
        print(output.render(["devices": devices]))
    } else {
        for (i, d) in devices.enumerated() {
            let sel = (d["selected"] as? Bool == true) ? "▶" : " "
            print("\(sel) \(i + 1). \(d["name"]!) [\(d["volume"]!)]")
        }
    }
}

// MARK: - Hidden subcommands (backwards compatibility)

struct SpeakerList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List AirPlay devices.", shouldDisplay: false)
    @Flag(name: .long, help: "Output JSON") var json = false
    func run() throws {
        try refuseInBridge(.airplayRoute, json: json)
        try listSpeakers(json: json)
    }
}

struct SpeakerSet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Switch to a single speaker.", shouldDisplay: false)
    @Argument(help: "Speaker name") var name: String
    func run() throws {
        try refuseInBridge(.airplayRoute)
        try runSpeakerSmart(args: [name, "only"], json: false)
    }
}

struct SpeakerAdd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Add speaker to group.", shouldDisplay: false)
    @Argument(help: "Speaker name") var name: String
    func run() throws {
        try refuseInBridge(.airplayRoute)
        try runSpeakerSmart(args: [name], json: false)
    }
}

struct SpeakerRemove: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove speaker from group.", shouldDisplay: false)
    @Argument(help: "Speaker name") var name: String
    func run() throws {
        try refuseInBridge(.airplayRoute)
        try runSpeakerSmart(args: [name, "stop"], json: false)
    }
}

struct SpeakerStop: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop", abstract: "Remove speaker (alias).", shouldDisplay: false)
    @Argument(help: "Speaker name") var name: String
    func run() throws {
        try refuseInBridge(.airplayRoute)
        try runSpeakerSmart(args: [name, "stop"], json: false)
    }
}
