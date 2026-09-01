// tools/music/Sources/TUI/AlbumContainer.swift
import Foundation

/// Temporary container for a bounded CLI album play.
///
/// Shape mirrors the Discover container: "__album__ <uuid> — <title>". The uuid
/// makes the name collision proof, replacing the one second timestamp the two
/// `__temp__` creators use. The title after the separator is DISPLAY ONLY and is
/// never used as an identifier; `cleanContextName` reads it back out for Now
/// Playing.
let albumPlaylistPrefix = "__album__ "

/// Prefixes whose names carry "<uuid><separator><title>" after the prefix.
///
/// An explicit list, deliberately. A generic "strip anything uuid shaped" rule
/// would rewrite a user's own playlist name that happened to match.
let uuidCarryingPlaylistPrefixes = [discoverPlaylistPrefix, albumPlaylistPrefix]

func albumContainerName(title: String, uuid: String) -> String {
    albumPlaylistPrefix + uuid + discoverPlaylistNameSeparator + title
}
