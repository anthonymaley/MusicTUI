// tools/music/Sources/PlaySync/PersistentIDAlias.swift
import Foundation

/// The Music.app persistent ID, as sixteen uppercase hex digits, for the alias
/// Bridge reports with a finished library play.
///
/// The alias is the same 64-bit identity written as a signed decimal, so this
/// is a change of notation, not a mapping between two id spaces: the bits are
/// reinterpreted, never looked up or computed from anything else.
///
/// Accepts exactly an optional `-` followed by 1 to 20 ASCII digits. A value
/// that overflows a signed 64-bit integer is accepted when it still fits
/// unsigned. Never goes through floating point. Anything else is nil, and the
/// play is left unrecorded rather than written to a guessed track.
func persistentIDHex(fromAlias alias: String) -> String? {
    let utf8 = Array(alias.utf8)
    let digits = utf8.first == UInt8(ascii: "-") ? utf8.dropFirst() : utf8[...]
    guard (1...20).contains(digits.count),
          digits.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) else {
        return nil
    }
    let value: UInt64
    if let signed = Int64(alias) {
        value = UInt64(bitPattern: signed)
    } else if let unsigned = UInt64(alias) {
        value = unsigned
    } else {
        return nil
    }
    return String(format: "%016llX", value)
}
