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
}

struct SpeakerParser {
    static func parse(_ args: [String]) -> SpeakerAction {
        guard !args.isEmpty else { return .interactive }
        if args.count == 1 && args[0].lowercased() == "list" { return .list }
        if args.count >= 1 && args[0].lowercased() == "wake" {
            let name = args.count > 1 ? args.dropFirst().joined(separator: " ") : nil
            return .wake(name: name)
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
    @Argument(help: "Speaker name, index, volume, or keyword (stop/only/list/wake)") var args: [String] = []
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
            try await backend.runMusic("set selected of AirPlay device \"\(resolved)\" to true")
        }
        print("Added \(resolved).")

    case .addWithVolume(let name, let volume):
        let resolved = try resolveSpeakerName(name, backend: backend)
        _ = try syncRun {
            try await backend.runMusic("set selected of AirPlay device \"\(resolved)\" to true")
        }
        _ = try syncRun {
            try await backend.runMusic("set sound volume of AirPlay device \"\(resolved)\" to \(volume)")
        }
        print("Added \(resolved) [\(volume)].")

    case .remove(let name):
        let resolved = try resolveSpeakerName(name, backend: backend)
        _ = try syncRun {
            try await backend.runMusic("set selected of AirPlay device \"\(resolved)\" to false")
        }
        print("Removed \(resolved).")

    case .exclusive(let name):
        let resolved = try resolveSpeakerName(name, backend: backend)
        _ = try syncRun {
            try await backend.runMusic("""
                set allDevices to every AirPlay device
                repeat with d in allDevices
                    set selected of d to false
                end repeat
            """)
        }
        _ = try syncRun {
            try await backend.runMusic("set selected of AirPlay device \"\(resolved)\" to true")
        }
        print("Switched to \(resolved) only.")

    case .indices(let idxs):
        let cache = ResultCache()
        for idx in idxs {
            let speaker = try cache.lookupSpeaker(index: idx)
            _ = try syncRun {
                try await backend.runMusic("set selected of AirPlay device \"\(speaker.name)\" to true")
            }
            print("Added \(speaker.name).")
        }

    case .wake(let name):
        let targetNames: [String]
        if let name = name {
            let resolved = try resolveSpeakerName(name, backend: backend)
            targetNames = [resolved]
        } else {
            let devices = try fetchSpeakerDevices()
            targetNames = devices.filter { $0["selected"] as? Bool == true }.map { $0["name"] as! String }
            if targetNames.isEmpty {
                print("No active speakers to wake.")
                return
            }
        }

        let results = withStatus("Waking speakers...") {
            wakeSpeakers(targetNames, backend: backend)
        }

        for r in results {
            if r.verifiedSelected {
                print("Woke \(r.name).")
            } else {
                print("\(r.name): wake cycle completed but verification uncertain.")
            }
        }
    }
}

private func runSpeakerTUI() throws {
    let devices = try fetchSpeakerDevices()
    var volumes = devices.map { $0["volume"] as! Int }
    var items = devices.map {
        MultiSelectItem(label: $0["name"] as! String, sublabel: "vol: \($0["volume"]!)", selected: $0["selected"] as! Bool)
    }

    let backend = AppleScriptBackend()
    let result = runMultiSelectList(title: "AirPlay Speakers", items: &items, onToggle: { idx, selected in
        let name = devices[idx]["name"] as! String
        _ = try? syncRun {
            try await backend.runMusic("set selected of AirPlay device \"\(name)\" to \(selected)")
        }
    }, onAdjust: { idx, delta in
        volumes[idx] = min(100, max(0, volumes[idx] + delta))
        let name = devices[idx]["name"] as! String
        let vol = volumes[idx]
        _ = try? syncRun {
            try await backend.runMusic("set sound volume of AirPlay device \"\(name)\" to \(vol)")
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
}

func fetchSpeakerDevices() throws -> [[String: Any]] {
    let backend = AppleScriptBackend()
    let result = try syncRun {
        try await backend.runMusic("""
            set deviceList to every AirPlay device
            set output to ""
            repeat with d in deviceList
                if output is not "" then set output to output & linefeed
                set output to output & name of d & "|" & selected of d & "|" & sound volume of d & "|" & kind of d
            end repeat
            return output
        """)
    }
    let lines = result.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n")
    return lines.compactMap { line in
        let parts = line.split(separator: "|", maxSplits: 3).map(String.init)
        guard parts.count >= 4 else { return nil }
        return [
            "name": parts[0],
            "selected": parts[1] == "true",
            "volume": Int(parts[2]) ?? 0,
            "kind": parts[3]
        ]
    }
}

// MARK: - Wake cycle

struct WakeResult {
    let name: String
    let deselectSucceeded: Bool
    let reselectSucceeded: Bool
    let verifiedSelected: Bool
}

func wakeSpeakers(_ names: [String], backend: AppleScriptBackend) -> [WakeResult] {
    var results: [WakeResult] = []

    for name in names {
        verbose("deselecting \(name)...")
        let deselectOk: Bool
        do {
            _ = try syncRun {
                try await backend.runMusic("set selected of AirPlay device \"\(name)\" to false")
            }
            deselectOk = true
        } catch {
            verbose("deselect failed for \(name): \(error.localizedDescription)")
            deselectOk = false
        }
        results.append(WakeResult(name: name, deselectSucceeded: deselectOk, reselectSucceeded: false, verifiedSelected: false))
    }

    // Wait for AirPlay stack to release
    verbose("waiting 500ms for AirPlay release...")
    Thread.sleep(forTimeInterval: 0.5)

    for i in results.indices {
        let name = results[i].name
        verbose("reselecting \(name)...")
        let reselectOk: Bool
        do {
            _ = try syncRun {
                try await backend.runMusic("set selected of AirPlay device \"\(name)\" to true")
            }
            reselectOk = true
        } catch {
            verbose("reselect failed for \(name): \(error.localizedDescription)")
            reselectOk = false
        }
        results[i] = WakeResult(name: name, deselectSucceeded: results[i].deselectSucceeded, reselectSucceeded: reselectOk, verifiedSelected: false)
    }

    // Wait for AirPlay stack to reconnect
    verbose("waiting 500ms for AirPlay reconnect...")
    Thread.sleep(forTimeInterval: 0.5)

    // Verify selection state
    for i in results.indices {
        let name = results[i].name
        let verified: Bool
        do {
            let state = try syncRun {
                try await backend.runMusic("get selected of AirPlay device \"\(name)\"")
            }
            verified = state.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
            verbose("\(name) verified selected: \(verified)")
        } catch {
            verbose("verification failed for \(name): \(error.localizedDescription)")
            verified = false
        }
        results[i] = WakeResult(name: name, deselectSucceeded: results[i].deselectSucceeded, reselectSucceeded: results[i].reselectSucceeded, verifiedSelected: verified)
    }

    return results
}

// MARK: - Speaker name resolution (case-insensitive prefix match)

func resolveSpeakerName(_ input: String, backend: AppleScriptBackend) throws -> String {
    let result = try syncRun {
        try await backend.runMusic("get name of every AirPlay device")
    }
    let names = result.trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }

    let lower = input.lowercased()
    verbose("resolving speaker \"\(input)\" against: \(names.joined(separator: ", "))")
    if let exact = names.first(where: { $0.lowercased() == lower }) {
        verbose("resolved \"\(input)\" → \"\(exact)\" (exact match)")
        return exact
    }
    if let prefix = names.first(where: { $0.lowercased().hasPrefix(lower) }) {
        verbose("resolved \"\(input)\" → \"\(prefix)\" (prefix match)")
        return prefix
    }
    if let contains = names.first(where: { $0.lowercased().contains(lower) }) {
        verbose("resolved \"\(input)\" → \"\(contains)\" (contains match)")
        return contains
    }

    let available = names.joined(separator: ", ")
    throw AppleScriptBackend.ScriptError.speakerNotFound("\(input)\" not found. Available: \(available)")
}

func listSpeakers(json: Bool) throws {
    let backend = AppleScriptBackend()
    let result = try syncRun {
        try await backend.runMusic("""
            set deviceList to every AirPlay device
            set output to ""
            repeat with d in deviceList
                if output is not "" then set output to output & linefeed
                set output to output & name of d & "|" & selected of d & "|" & sound volume of d & "|" & kind of d
            end repeat
            return output
        """)
    }
    let lines = result.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n")
    let devices: [[String: Any]] = lines.compactMap { line in
        let parts = line.split(separator: "|", maxSplits: 3).map(String.init)
        guard parts.count >= 4 else { return nil }
        return [
            "name": parts[0],
            "selected": parts[1] == "true",
            "volume": Int(parts[2]) ?? 0,
            "kind": parts[3]
        ]
    }

    let cache = ResultCache()
    let speakerResults = devices.enumerated().map { (i, d) in
        SpeakerResult(
            index: i + 1,
            name: d["name"] as! String,
            selected: d["selected"] as! Bool,
            volume: d["volume"] as! Int
        )
    }
    try? cache.writeSpeakers(speakerResults)

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
