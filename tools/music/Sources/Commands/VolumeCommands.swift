import ArgumentParser
import Foundation

struct Vol: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "volume", abstract: "Get or set volume.")
    @Argument(help: "Volume level (0-100), 'up', 'down', or speaker name") var args: [String] = []
    @Flag(name: .long, help: "Output JSON") var json = false

    func run() throws {
        let backend = AppleScriptBackend()

        if args.isEmpty {
            if !json && isTTY() {
                // Interactive volume mixer
                let result = try syncRun {
                    try await backend.runMusic("""
                        set deviceList to every AirPlay device
                        set output to ""
                        repeat with d in deviceList
                            if selected of d then
                                if output is not "" then set output to output & linefeed
                                set output to output & name of d & "|" & sound volume of d
                            end if
                        end repeat
                        return output
                    """)
                }
                let lines = result.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n")
                var speakers: [MixerSpeaker] = lines.compactMap { line in
                    let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
                    guard parts.count >= 2, let vol = Int(parts[1]) else { return nil }
                    return MixerSpeaker(name: parts[0], volume: vol)
                }

                runVolumeMixer(speakers: &speakers) { name, volume in
                    _ = try? syncRun {
                        try await backend.runMusic("set sound volume of AirPlay device \"\(name)\" to \(volume)")
                    }
                }
                return
            }

            // Non-interactive: show current volumes
            let result = try syncRun {
                try await backend.runMusic("""
                    set deviceList to every AirPlay device
                    set output to ""
                    repeat with d in deviceList
                        if selected of d then
                            if output is not "" then set output to output & ","
                            set output to output & name of d & ":" & sound volume of d
                        end if
                    end repeat
                    return output
                """)
            }
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            let speakers = trimmed.split(separator: ",").map { pair -> [String: Any] in
                let kv = pair.split(separator: ":", maxSplits: 1)
                return ["name": String(kv[0]), "volume": Int(kv.count > 1 ? String(kv[1]) : "0") ?? 0]
            }
            if json {
                let output = OutputFormat(mode: .json)
                print(output.render(["speakers": speakers]))
            } else {
                for s in speakers {
                    print("\(s["name"]!) [\(s["volume"]!)]")
                }
            }
            return
        }

        // Single arg: number, "up", or "down"
        if args.count == 1 {
            let arg = args[0].lowercased()
            if arg == "up" || arg == "down" {
                let delta = arg == "up" ? 10 : -10
                let result = try syncRun {
                    try await backend.runMusic("""
                        set deviceList to every AirPlay device
                        set output to ""
                        repeat with d in deviceList
                            if selected of d then
                                set newVol to (sound volume of d) + \(delta)
                                if newVol > 100 then set newVol to 100
                                if newVol < 0 then set newVol to 0
                                set sound volume of d to newVol
                                if output is not "" then set output to output & ", "
                                set output to output & name of d & " [" & newVol & "]"
                            end if
                        end repeat
                        return output
                    """)
                }
                print(result.trimmingCharacters(in: .whitespacesAndNewlines))
            } else if let vol = Int(arg) {
                let result = try syncRun {
                    try await backend.runMusic("""
                        set deviceList to every AirPlay device
                        set output to ""
                        repeat with d in deviceList
                            if selected of d then
                                set sound volume of d to \(vol)
                                if output is not "" then set output to output & ", "
                                set output to output & name of d
                            end if
                        end repeat
                        return "\(vol) — " & output
                    """)
                }
                print(result.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return
        }

        // Two+ args: last is volume number, rest is speaker name
        if let vol = Int(args.last!) {
            let speakerName = args.dropLast().joined(separator: " ")
            let resolved = try resolveSpeakerName(speakerName, backend: backend)
            _ = try syncRun {
                try await backend.runMusic("set sound volume of AirPlay device \"\(resolved)\" to \(vol)")
            }
            print("\(resolved) [\(vol)]")
        }
    }
}
