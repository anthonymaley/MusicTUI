import ArgumentParser
import Foundation

struct Play: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Play or resume music.")

    @Option(name: .long, help: "Playlist name") var playlist: String?
    @Option(name: .long, help: "Song name") var song: String?
    @Option(name: .long, help: "Artist name") var artist: String?
    @Flag(name: .long, help: "Output JSON") var json = false

    func run() throws {
        let backend = AppleScriptBackend()
        let output = OutputFormat(mode: json ? .json : .human)

        if let playlist = playlist {
            let result = try syncRun {
                try await backend.runMusic("""
                    set shuffle enabled to true
                    play playlist "\(playlist)"
                    return name of current track & "|" & artist of current track
                """)
            }
            let parts = result.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|")
            if parts.count >= 2 {
                print(output.render(["track": String(parts[0]), "artist": String(parts[1]), "playlist": playlist]))
            }
        } else if let song = song {
            let artistFilter = artist.map { " and artist contains \"\($0)\"" } ?? ""
            let result = try syncRun {
                try await backend.runMusic("""
                    set results to (every track of playlist "Library" whose name contains "\(song)"\(artistFilter))
                    if (count of results) > 0 then
                        play item 1 of results
                        return name of current track & "|" & artist of current track
                    else
                        return "NOT_FOUND"
                    end if
                """)
            }
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "NOT_FOUND" {
                print("No tracks found matching '\(song)'")
                throw ExitCode.failure
            }
            let parts = trimmed.split(separator: "|")
            if parts.count >= 2 {
                print(output.render(["track": String(parts[0]), "artist": String(parts[1])]))
            }
        } else {
            let result = try syncRun {
                try await backend.runMusic("""
                    play
                    return name of current track & "|" & artist of current track
                """)
            }
            let parts = result.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|")
            if parts.count >= 2 {
                print(output.render(["track": String(parts[0]), "artist": String(parts[1])]))
            }
        }
    }
}

struct Pause: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Pause playback.")
    func run() throws {
        let backend = AppleScriptBackend()
        _ = try syncRun { try await backend.runMusic("pause") }
        print("Paused.")
    }
}

struct Skip: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Skip to next track.")
    @Flag(name: .long, help: "Output JSON") var json = false
    func run() throws {
        let backend = AppleScriptBackend()
        let result = try syncRun {
            try await backend.runMusic("""
                next track
                return name of current track & "|" & artist of current track
            """)
        }
        let output = OutputFormat(mode: json ? .json : .human)
        let parts = result.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|")
        if parts.count >= 2 {
            print(output.render(["track": String(parts[0]), "artist": String(parts[1])]))
        }
    }
}

struct Back: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Go to previous track.")
    @Flag(name: .long, help: "Output JSON") var json = false
    func run() throws {
        let backend = AppleScriptBackend()
        let result = try syncRun {
            try await backend.runMusic("""
                previous track
                return name of current track & "|" & artist of current track
            """)
        }
        let output = OutputFormat(mode: json ? .json : .human)
        let parts = result.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|")
        if parts.count >= 2 {
            print(output.render(["track": String(parts[0]), "artist": String(parts[1])]))
        }
    }
}

struct Stop: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop playback.")
    func run() throws {
        let backend = AppleScriptBackend()
        _ = try syncRun { try await backend.runMusic("stop") }
        print("Stopped.")
    }
}

struct Now: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show what's currently playing.")
    @Flag(name: .long, help: "Output JSON") var json = false
    func run() throws {
        let backend = AppleScriptBackend()
        let result = try syncRun {
            try await backend.runMusic("""
                set state to player state as text
                if state is "stopped" then
                    return "STOPPED"
                end if
                set t to name of current track
                set a to artist of current track
                set al to album of current track
                set d to duration of current track
                set p to player position
                set spk to ""
                set deviceList to every AirPlay device
                repeat with dev in deviceList
                    if selected of dev then
                        if spk is not "" then set spk to spk & ","
                        set spk to spk & name of dev & ":" & sound volume of dev
                    end if
                end repeat
                return t & "|" & a & "|" & al & "|" & (round d) & "|" & (round p) & "|" & state & "|" & spk
            """)
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "STOPPED" {
            print(json ? "{\"state\":\"stopped\"}" : "Nothing playing.")
            return
        }
        let parts = trimmed.split(separator: "|", maxSplits: 6).map(String.init)
        guard parts.count >= 7 else { print("Unexpected output"); return }

        let speakers = parts[6].split(separator: ",").map { pair -> [String: Any] in
            let kv = pair.split(separator: ":", maxSplits: 1)
            return ["name": String(kv[0]), "volume": Int(kv.count > 1 ? String(kv[1]) : "0") ?? 0]
        }

        if json {
            let dict: [String: Any] = [
                "track": parts[0], "artist": parts[1], "album": parts[2],
                "duration": Int(parts[3]) ?? 0, "position": Int(parts[4]) ?? 0,
                "state": parts[5], "speakers": speakers
            ]
            let output = OutputFormat(mode: .json)
            print(output.render(dict))
        } else {
            let spkStr = speakers.map { "\($0["name"]!) (vol: \($0["volume"]!))" }.joined(separator: " | ")
            print("\(parts[0]) — \(parts[1]) [\(parts[2])]")
            if !spkStr.isEmpty { print(spkStr) }
        }
    }
}

struct Shuffle: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Toggle shuffle.")
    @Argument(help: "on or off") var state: String
    func run() throws {
        let backend = AppleScriptBackend()
        let val = state.lowercased() == "on" ? "true" : "false"
        _ = try syncRun { try await backend.runMusic("set shuffle enabled to \(val)") }
        print("Shuffle \(state.lowercased()).")
    }
}

struct Repeat_: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "repeat", abstract: "Set repeat mode.")
    @Argument(help: "off, one, or all") var mode: String
    func run() throws {
        let backend = AppleScriptBackend()
        _ = try syncRun { try await backend.runMusic("set song repeat to \(mode.lowercased())") }
        print("Repeat \(mode.lowercased()).")
    }
}

// MARK: - Sync helper for running async from sync ParsableCommand.run()

func syncRun<T>(_ block: @escaping () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Result<T, Error>!
    Task {
        do {
            result = .success(try await block())
        } catch {
            result = .failure(error)
        }
        semaphore.signal()
    }
    semaphore.wait()
    return try result.get()
}
