// tools/music/Sources/Commands/PositionalPlayRoute.swift
import Foundation

/// What a positional `music play "X"` resolved to.
///
/// The old implementation resolved BY PLAYING inside one AppleScript, so nothing
/// knew "this is an album" before audio started. Splitting the decision out is
/// what lets only the album outcome get the bounded treatment, and keeps the two
/// album routes on one implementation.
enum PositionalRoute: Equatable {
    /// `play playlist` already succeeded. Terminal: audio is running, so no
    /// further play may be issued. This is the no-double-start rule.
    case playlistAlreadyPlaying
    case boundedAlbum
    case song
    /// The album probe did not answer. Fail closed: routing on to the song
    /// branch could play a same-named song instead of the album asked for.
    case albumReadFailed
}

/// Pure. Precedence is playlist, then album, then song, exactly as before.
/// `albumRowCount` nil means the album read failed, which stops the route
/// rather than counting as zero rows.
func positionalRoute(playlistPlayed: Bool, albumRowCount: Int?) -> PositionalRoute {
    if playlistPlayed { return .playlistAlreadyPlaying }
    guard let albumRowCount else { return .albumReadFailed }
    return albumRowCount > 0 ? .boundedAlbum : .song
}
