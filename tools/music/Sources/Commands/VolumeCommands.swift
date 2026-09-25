import ArgumentParser
import Foundation

struct Vol: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "volume", abstract: "Get or set volume.")
    @Argument(help: "Volume level (0-100), 'up', 'down', or speaker name") var args: [String] = []
    @Flag(name: .long, help: "Output JSON") var json = false

    // Slice 3 S8: with Bridge selected, volume refuses first, in the TUI
    // table's words (Bridge plays at the Mac's output level).
    func run() throws {
        try refuseInBridge(.volume, json: json)
        let backend = AppleScriptBackend()

        if args.isEmpty {
            // One bulk enumeration (cache write-through) serves both modes.
            let active = try fetchSpeakerDevices().filter { $0["selected"] as? Bool == true }
            if !json && isTTY() {
                var speakers: [MixerSpeaker] = active.map {
                    MixerSpeaker(name: $0["name"] as! String, volume: $0["volume"] as! Int)
                }
                var actionErrors: [String] = []
                runVolumeMixer(speakers: &speakers) { name, volume in
                    do {
                        _ = try syncRun {
                            try await backend.runMusic("set sound volume of AirPlay device \"\(escapeAppleScriptString(name))\" to \(volume)")
                        }
                    } catch {
                        actionErrors.append("Couldn't set \(name) volume: \(error.localizedDescription)")
                    }
                }
                for message in actionErrors { errorOut("✗ \(message)") }
                return
            }

            // Non-interactive: show current volumes
            if json {
                let speakers = active.map { ["name": $0["name"]!, "volume": $0["volume"]!] }
                let output = OutputFormat(mode: .json)
                print(output.render(["speakers": speakers]))
            } else {
                for s in active {
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
                // Per-device try: one unreachable speaker must not abort the
                // volume change for the rest of the group.
                let result = try syncRun {
                    try await backend.runMusic("""
                        set output to ""
                        repeat with d in (every AirPlay device whose selected is true)
                            try
                                set newVol to (sound volume of d) + \(delta)
                                if newVol > 100 then set newVol to 100
                                if newVol < 0 then set newVol to 0
                                set sound volume of d to newVol
                                if output is not "" then set output to output & ", "
                                set output to output & name of d & " [" & newVol & "]"
                            end try
                        end repeat
                        return output
                    """)
                }
                let summary = result.trimmingCharacters(in: .whitespacesAndNewlines)
                print(json ? "{\"ok\":true,\"action\":\"\(arg)\"}" : summary)
            } else if let vol = Int(arg) {
                guard (0...100).contains(vol) else {
                    throw ValidationError("Volume must be 0-100.")
                }
                let result = try syncRun {
                    try await backend.runMusic("""
                        set output to ""
                        repeat with d in (every AirPlay device whose selected is true)
                            try
                                set sound volume of d to \(vol)
                                if output is not "" then set output to output & ", "
                                set output to output & name of d
                            end try
                        end repeat
                        return "\(vol) — " & output
                    """)
                }
                print(json ? "{\"ok\":true,\"volume\":\(vol)}" : result.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                // `music volume abc` used to exit 0 with no output at all.
                throw ValidationError("Volume must be 0-100, 'up', 'down', or a speaker name + volume.")
            }
            return
        }

        // Two+ args: last is volume number, rest is speaker name
        guard let vol = Int(args.last!) else {
            throw ValidationError("Last argument must be a volume (0-100), e.g. `music volume kitchen 40`.")
        }
        guard (0...100).contains(vol) else {
            throw ValidationError("Volume must be 0-100.")
        }
        let speakerName = args.dropLast().joined(separator: " ")
        let resolved = try resolveSpeakerName(speakerName, backend: backend)
        _ = try syncRun {
            try await backend.runMusic("set sound volume of AirPlay device \"\(escapeAppleScriptString(resolved))\" to \(vol)")
        }
        print(json ? "{\"ok\":true,\"speaker\":\"\(resolved)\",\"volume\":\(vol)}" : "\(resolved) [\(vol)]")
    }
}
