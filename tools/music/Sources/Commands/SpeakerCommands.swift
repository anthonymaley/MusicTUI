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
        Music.verbose = verbose
        Music.isJSON = json
        try runSpeakerSmart(args: args, json: json)
    }
}

// MARK: - Shared logic (callable without ArgumentParser)

func runSpeakerSmart(args: [String], json: Bool) throws {
    let action = SpeakerParser.parse(args)
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
        _ = try syncRun {
            try await backend.runMusic("set selected of AirPlay device \"\(escapeAppleScriptString(resolved))\" to true")
        }
        print("Added \(resolved).")

    case .addWithVolume(let name, let volume):
        let resolved = try resolveSpeakerName(name, backend: backend)
        _ = try syncRun {
            try await backend.runMusic("set selected of AirPlay device \"\(escapeAppleScriptString(resolved))\" to true")
        }
        _ = try syncRun {
            try await backend.runMusic("set sound volume of AirPlay device \"\(escapeAppleScriptString(resolved))\" to \(volume)")
        }
        print("Added \(resolved) [\(volume)].")

    case .remove(let name):
        let resolved = try resolveSpeakerName(name, backend: backend)
        _ = try syncRun {
            try await backend.runMusic("set selected of AirPlay device \"\(escapeAppleScriptString(resolved))\" to false")
        }
        print("Removed \(resolved).")

    case .exclusive(let name):
        let resolved = try resolveSpeakerName(name, backend: backend)
        // Select the target FIRST: the old deselect-all-then-select could end
        // with NO outputs at all if the target failed after the teardown. Also
        // per-device try — one unreachable device must not abort the rest (an
        // AppleScript repeat dies on the first error otherwise).
        _ = try syncRun {
            try await backend.runMusic("set selected of AirPlay device \"\(escapeAppleScriptString(resolved))\" to true")
        }
        _ = try syncRun {
            try await backend.runMusic("""
                repeat with d in (every AirPlay device)
                    try
                        if name of d is not "\(escapeAppleScriptString(resolved))" and selected of d then
                            set selected of d to false
                        end if
                    end try
                end repeat
            """)
        }
        print("Switched to \(resolved) only.")

    case .indices(let idxs):
        let cache = ResultCache()
        for idx in idxs {
            let speaker = try cache.lookupSpeaker(index: idx)
            _ = try syncRun {
                try await backend.runMusic("set selected of AirPlay device \"\(escapeAppleScriptString(speaker.name))\" to true")
            }
            print("Added \(speaker.name).")
        }

    case .wake(let name):
        if let name = name {
            // Wake a specific speaker: select it, then reset to establish a clean connection
            let resolved = try resolveSpeakerName(name, backend: backend)
            do {
                _ = try syncRun {
                    try await backend.runMusic("set selected of AirPlay device \"\(escapeAppleScriptString(resolved))\" to true")
                }
            } catch {
                // A sleeping device erroring on first select is the very case
                // wake exists for — say so instead of dumping AppleScript noise.
                throw AppleScriptBackend.ScriptError.speakerUnavailable(resolved)
            }
        }
        let reset = withStatus("Resetting AirPlay speakers...") {
            resetAirPlaySpeakers(backend: backend)
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

    case .verify(let name):
        try runSpeakerVerify(name: name, backend: backend, json: json)
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
        guard let ip = verifier.resolver.resolveIP(forSpeaker: target) else {
            results.append(["name": target, "verified": false, "ip": "",
                            "evidence": "could not resolve IP via Bonjour — cannot verify",
                            "claimedSelected": claimed])
            continue
        }
        let verdict = try verifier.steadyState(ip: ip)
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
        let mark = (r["verified"] as? Bool == true) ? "✓" : "✗"
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
            _ = try syncRun {
                try await backend.runMusic("set selected of AirPlay device \"\(escapeAppleScriptString(name))\" to \(selected)")
            }
        } catch {
            actionErrors.append("Couldn't \(selected ? "add" : "remove") \(name): \(error.localizedDescription)")
        }
    }, onAdjust: { idx, delta in
        volumes[idx] = min(100, max(0, volumes[idx] + delta))
        let name = devices[idx]["name"] as! String
        let vol = volumes[idx]
        do {
            _ = try syncRun {
                try await backend.runMusic("set sound volume of AirPlay device \"\(escapeAppleScriptString(name))\" to \(vol)")
            }
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
    let blocks = raw
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .components(separatedBy: speakerBlockSeparator.trimmingCharacters(in: .whitespaces))
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard blocks.count >= 4 else { return [] }
    let names = blocks[0].components(separatedBy: "\n")
    let sels = blocks[1].components(separatedBy: "\n")
    let vols = blocks[2].components(separatedBy: "\n")
    let kinds = blocks[3].components(separatedBy: "\n")
    guard names.count == sels.count, names.count == vols.count, names.count == kinds.count else { return [] }
    return (0..<names.count).compactMap { i in
        guard !names[i].isEmpty else { return nil }
        return [
            "name": names[i],
            "selected": sels[i] == "true",
            "volume": Int(vols[i]) ?? 0,
            "kind": kinds[i]
        ]
    }
}

/// All AirPlay devices in one osascript with 4 bulk Apple Events — measured 6x
/// faster than the old per-device property loop (0.21s vs 1.23s, 11 devices).
/// Write-through to the speakers cache so name resolution can skip the live
/// round-trip entirely.
func fetchSpeakerDevices() throws -> [[String: Any]] {
    let backend = AppleScriptBackend()
    let result = try syncRun {
        try await backend.runMusic("""
            set astid to AppleScript's text item delimiters
            set AppleScript's text item delimiters to linefeed
            set ns to (name of every AirPlay device) as text
            set sels to (selected of every AirPlay device) as text
            set vols to (sound volume of every AirPlay device) as text
            set ks to (kind of every AirPlay device) as text
            set AppleScript's text item delimiters to astid
            set sep to linefeed & "=====" & linefeed
            return ns & sep & sels & sep & vols & sep & ks
        """, timeout: 20)
    }
    let devices = parseSpeakerDeviceBlocks(result)
    if !devices.isEmpty {
        let speakerResults = devices.enumerated().map { (i, d) in
            SpeakerResult(index: i + 1, name: d["name"] as! String,
                          selected: d["selected"] as! Bool, volume: d["volume"] as! Int)
        }
        try? ResultCache().writeSpeakers(speakerResults)
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
func resetAirPlaySpeakers(backend: AppleScriptBackend) -> [SpeakerSnapshot] {
    guard let devices = try? fetchSpeakerDevices() else {
        errorOut("✗ Couldn't enumerate AirPlay speakers to reset.")
        verbose("reset: fetchSpeakerDevices failed, skipping")
        return []
    }
    let nonLocal = devices.filter {
        ($0["selected"] as? Bool == true) && ($0["kind"] as? String != "computer")
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
            _ = try syncRun {
                try await backend.runMusic("set selected of AirPlay device \"\(escapeAppleScriptString(s.name))\" to false")
            }
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
            _ = try syncRun {
                try await backend.runMusic("set selected of AirPlay device \"\(escapeAppleScriptString(s.name))\" to true")
            }
        } catch {
            verbose("reselect failed for \(s.name): \(error.localizedDescription)")
        }
    }

    // Restore per-speaker volumes (deselect can reset to default)
    for s in speakers {
        do {
            _ = try syncRun {
                try await backend.runMusic("set sound volume of AirPlay device \"\(escapeAppleScriptString(s.name))\" to \(s.volume)")
            }
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

// MARK: - Speaker name resolution (case-insensitive exact > prefix > contains)

/// Pure match against a name list.
func matchSpeakerName(_ input: String, in names: [String]) -> String? {
    let lower = input.lowercased()
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
        try listSpeakers(json: json)
    }
}

struct SpeakerSet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Switch to a single speaker.", shouldDisplay: false)
    @Argument(help: "Speaker name") var name: String
    func run() throws {
        try runSpeakerSmart(args: [name, "only"], json: false)
    }
}

struct SpeakerAdd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Add speaker to group.", shouldDisplay: false)
    @Argument(help: "Speaker name") var name: String
    func run() throws {
        try runSpeakerSmart(args: [name], json: false)
    }
}

struct SpeakerRemove: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove speaker from group.", shouldDisplay: false)
    @Argument(help: "Speaker name") var name: String
    func run() throws {
        try runSpeakerSmart(args: [name, "stop"], json: false)
    }
}

struct SpeakerStop: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop", abstract: "Remove speaker (alias).", shouldDisplay: false)
    @Argument(help: "Speaker name") var name: String
    func run() throws {
        try runSpeakerSmart(args: [name, "stop"], json: false)
    }
}
