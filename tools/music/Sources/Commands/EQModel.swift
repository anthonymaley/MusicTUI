// MARK: - EQ domain logic (pure, unit-testable)
// Venue preset curves, sparkline rendering.
// No AppleScript here — everything is tested in EQModelTests.

import Foundation

struct VenuePreset: Equatable {
    let name: String
    let bands: [Double]   // 10 gains in dB: 32, 64, 125, 250, 500, 1K, 2K, 4K, 8K, 16K Hz
    let preamp: Double
}

enum VenuePack {
    /// Starting curves from the design spec — tuned by ear at live verification.
    static let all: [VenuePreset] = [
        VenuePreset(name: "Nightclub",    bands: [8, 7, 4, 1, -2, -3, -1, 2, 4, 5],      preamp: -3),
        VenuePreset(name: "Dungeon",      bands: [6, 5, 4, 2, 0, -2, -4, -6, -8, -10],   preamp: 0),
        VenuePreset(name: "Open Air",     bands: [1, 2, 2, 1, 1, 2, 3, 3, 4, 4],         preamp: -1),
        VenuePreset(name: "Concert Hall", bands: [3, 3, 2, 1, 0, 0, 1, 2, 3, 2],         preamp: -1),
        VenuePreset(name: "Jazz Club",    bands: [3, 2, 1, 1, 2, 2, 1, 0, -1, -2],       preamp: 0),
        VenuePreset(name: "Stadium",      bands: [7, 6, 3, 0, -2, -2, 0, 3, 5, 6],       preamp: -3),
        VenuePreset(name: "Cathedral",    bands: [4, 3, 0, -2, -4, -3, 0, 3, 5, 6],      preamp: -1),
        VenuePreset(name: "Late Night",   bands: [2, 4, 3, 1, 0, 0, 1, 2, 3, 2],         preamp: 0),
    ]
    static let names: [String] = all.map(\.name)
    static func preset(named name: String) -> VenuePreset? {
        all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

/// One-line curve rendering: −12…+12 dB → ▁▂▃▄▅▆▇█
func eqSparkline(_ bands: [Double]) -> String {
    let glyphs = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
    return bands.map { gain in
        let t = (min(12, max(-12, gain)) + 12) / 24          // 0…1
        return glyphs[Int((t * 7).rounded())]
    }.joined()
}
