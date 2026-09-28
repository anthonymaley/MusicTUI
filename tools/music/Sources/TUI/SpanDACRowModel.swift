// The Output tab's SpanDAC row model (score: pairing redesign, C-ROW).
//
// This step only seeds the types other steps will fill and draw from; it
// changes no behaviour. `SpanDACOutputRow.state`/`.output` and
// `SourceStatus.output` (added elsewhere in this step) default so every
// existing call site keeps compiling unchanged.
import Foundation

/// Whether a SpanDAC reports a DAC attached to its output.
enum DACPresence: Equatable {
    case connected
    case notConnected
    case unknown
}

/// What a SpanDAC reports about its output (`slice.status` field `output`).
struct SourceOutputInfo: Equatable {
    let dac: DACPresence
    /// Only when `dac == .connected`.
    let name: String?
    /// Only where the device measures it.
    let maxRateHz: Int?
}

/// The Output tab's state for one SpanDAC row.
enum SpanDACRowState: Equatable {
    /// Also covers an explicit `output.dac == .unknown` reply (C-STATUS).
    case checking
    case ready
    /// `pairable` is a TXT `pair=1` hint, not a guarantee (C-TXT).
    case notPaired(pairable: Bool)
    /// The device refused: busy / too_many / closed (C-TXT).
    case notPairableNow(String)
    case connecting
    /// "Tap Allow on <device>.  m:ss left"
    case waitingForAllow(deadline: Date)
    /// TLS -9864: the pair is kept, not deleted.
    case forgotten
    /// TLS -9820 / -9846.
    case needsRepair(String)
    /// Answered, but cannot play (e.g. no DAC).
    case notReady(String)
    /// Not seen, asleep, or no answer.
    case unreachable(String)
    case forgetPrompt
}
