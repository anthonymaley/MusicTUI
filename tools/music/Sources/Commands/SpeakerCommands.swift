import ArgumentParser
import Foundation

struct Speaker: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage AirPlay speakers.",
        subcommands: [SpeakerList.self, SpeakerSet.self, SpeakerAdd.self, SpeakerRemove.self, SpeakerStop.self],
        defaultSubcommand: SpeakerList.self
    )
}

struct SpeakerList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List AirPlay devices.")
    @Flag(name: .long, help: "Output JSON") var json = false
    func run() throws {
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
        if json {
            let output = OutputFormat(mode: .json)
            print(output.render(["devices": devices]))
        } else {
            for d in devices {
                let sel = (d["selected"] as? Bool == true) ? "▶" : " "
                print("\(sel) \(d["name"]!) [\(d["volume"]!)]")
            }
        }
    }
}

struct SpeakerSet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Switch to a single speaker.")
    @Argument(help: "Speaker name") var name: String
    func run() throws {
        let backend = AppleScriptBackend()
        // Split into two separate osascript calls to avoid parameter error -50
        _ = try syncRun {
            try await backend.runMusic("""
                set allDevices to every AirPlay device
                repeat with d in allDevices
                    set selected of d to false
                end repeat
            """)
        }
        _ = try syncRun {
            try await backend.runMusic("set selected of AirPlay device \"\(name)\" to true")
        }
        print("Switched to \(name).")
    }
}

struct SpeakerAdd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Add speaker to group.")
    @Argument(help: "Speaker name") var name: String
    func run() throws {
        let backend = AppleScriptBackend()
        _ = try syncRun {
            try await backend.runMusic("set selected of AirPlay device \"\(name)\" to true")
        }
        print("Added \(name).")
    }
}

struct SpeakerRemove: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove speaker from group.")
    @Argument(help: "Speaker name") var name: String
    func run() throws {
        let backend = AppleScriptBackend()
        _ = try syncRun {
            try await backend.runMusic("set selected of AirPlay device \"\(name)\" to false")
        }
        print("Removed \(name).")
    }
}

struct SpeakerStop: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop", abstract: "Remove a speaker from the group (alias for remove).")
    @Argument(help: "Speaker name") var name: String
    func run() throws {
        let backend = AppleScriptBackend()
        _ = try syncRun {
            try await backend.runMusic("set selected of AirPlay device \"\(name)\" to false")
        }
        print("Stopped \(name).")
    }
}
