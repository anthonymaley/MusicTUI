// tools/music/Sources/TUI/AlbumWatcherManifest.swift
import Foundation

/// Private handoff file for a container's persistent ID set, used only when the
/// album exceeds `albumWatcherInlineIDLimit` tracks and the ids would make an
/// unreasonable argument list.
///
/// Written by the invoking command, OWNED BY THE WATCHER: the watcher removes it
/// on every exit path, including the max lifetime timeout. Owner only, since it
/// sits beside the auth files and this app writes 0600 by convention.
func albumManifestPath(uuid: String) -> String? {
    // Guard: reject any uuid containing "/" or ".." to prevent path traversal.
    // A malicious caller passing something with "/" or ".." could make
    // removeItem delete arbitrary trees, so we fail safe here.
    guard !uuid.contains("/") && !uuid.contains("..") else {
        return nil
    }
    let dir = "\(NSHomeDirectory())/.config/music"
    return "\(dir)/album-watch-\(uuid).ids"
}

@discardableResult
func writeAlbumManifest(uuid: String, ids: Set<String>) throws -> String {
    guard let path = albumManifestPath(uuid: uuid) else {
        throw NSError(domain: "AlbumWatcherManifest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid uuid"])
    }
    let dir = (path as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: dir,
                                            withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    // The dir is tightened even if it already exists, since `createDirectory`
    // only sets the mode when it creates. Mirrors AuthManager.writeSecure.
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
    try ids.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    return path
}

func readAlbumManifest(path: String) -> Set<String>? {
    guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    let ids = raw.split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    return Set(ids)
}

func removeAlbumManifest(path: String) {
    try? FileManager.default.removeItem(atPath: path)
}
