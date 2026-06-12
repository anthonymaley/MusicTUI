import ArgumentParser
import Foundation

struct EQ: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "eq",
        abstract: "Control the Music equalizer and venue presets.")
    @Argument(help: "Preset name, 'list', 'on', 'off', 'remove-pack', or empty for status")
    var args: [String] = []
    @Flag(name: .long, help: "Output JSON") var json = false

    func run() throws {
        let backend = AppleScriptBackend()
        let word = args.joined(separator: " ").lowercased()

        switch word {
        case "":
            try printStatus(backend)
        case "list":
            try printList(backend)
        case "on", "off":
            let enabling = word == "on"
            try eqSetEnabled(backend, enabling)
            print(json ? "{\"ok\":true,\"enabled\":\(enabling)}" : "EQ \(word)")
        case "remove-pack":
            var removed: [String] = []
            for name in VenuePack.names {
                if try eqDeletePreset(backend, name: name) { removed.append(name) }
            }
            if json {
                let names = removed.map { "\"\($0)\"" }.joined(separator: ",")
                print("{\"ok\":true,\"removed\":[\(names)]}")
            } else {
                print(removed.isEmpty ? "No venue presets installed."
                                      : "Removed: \(removed.joined(separator: ", "))")
            }
        default:
            try selectPreset(backend, query: args.joined(separator: " "))
        }
    }

    private func printStatus(_ backend: AppleScriptBackend) throws {
        let snap = try fetchEQSnapshot(backend)
        let bands = snap.current.flatMap { try? fetchEQBands(backend, name: $0) }
        if json {
            let cur = snap.current.map { "\"\($0)\"" } ?? "null"
            print("{\"enabled\":\(snap.enabled),\"preset\":\(cur)}")
        } else {
            let state = snap.enabled ? "on" : "off"
            let preset = snap.current ?? "none"
            let spark = bands.map { "  " + eqSparkline($0) } ?? ""
            print("EQ \(state) — \(preset)\(spark)")
        }
    }

    private func printList(_ backend: AppleScriptBackend) throws {
        let snap = try fetchEQSnapshot(backend)
        let installed = Set(snap.presets)
        if json {
            let names = snap.presets.map { "\"\($0)\"" }.joined(separator: ",")
            print("{\"presets\":[\(names)]}")
            return
        }
        print("Venue pack:")
        for p in VenuePack.all {
            let mark = p.name == snap.current ? "●" : (installed.contains(p.name) ? "✓" : " ")
            print("  \(mark) \(p.name)  \(eqSparkline(p.bands))")
        }
        print("Music presets:")
        for name in snap.presets where VenuePack.preset(named: name) == nil {
            let mark = name == snap.current ? "●" : " "
            print("  \(mark) \(name)")
        }
    }

    private func selectPreset(_ backend: AppleScriptBackend, query: String) throws {
        let snap = try fetchEQSnapshot(backend)
        // Venue names first: pack precedence, and uninstalled venues stay selectable.
        var available = VenuePack.names
        available += snap.presets.filter { VenuePack.preset(named: $0) == nil }
        switch EQNameResolver.resolve(query, in: available) {
        case .match(let name):
            if let venue = VenuePack.preset(named: name) {
                try eqEnsurePreset(backend, preset: venue)
            }
            try eqSetCurrent(backend, name: name)
            try eqSetEnabled(backend, true)
            let bands = (try? fetchEQBands(backend, name: name)) ?? []
            print(json ? "{\"ok\":true,\"preset\":\"\(name)\"}"
                       : "EQ on — \(name)  \(eqSparkline(bands))")
        case .ambiguous(let names):
            throw ValidationError("Did you mean: \(names.joined(separator: ", "))?")
        case .none:
            throw ValidationError("No preset matches '\(query)'. Try `music eq list`.")
        }
    }
}
