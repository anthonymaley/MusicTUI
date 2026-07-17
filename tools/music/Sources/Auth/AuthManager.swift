import Foundation

struct AuthConfig: Codable {
    let keyId: String
    let teamId: String
    let keyPath: String
    let storefront: String
}

struct AuthManager {
    static let configDir = NSString(string: "~/.config/music").expandingTildeInPath
    static let configPath = "\(configDir)/config.json"
    static let userTokenPath = "\(configDir)/user-token"

    func loadConfig() -> AuthConfig? {
        guard let data = FileManager.default.contents(atPath: Self.configPath),
              let config = try? JSONDecoder().decode(AuthConfig.self, from: data) else {
            return nil
        }
        return config
    }

    /// Like `loadConfig`, but distinguishes a malformed config (throws
    /// `.configCorrupt`) from a genuinely absent one (returns nil). The require*
    /// paths use this so a broken config is reported as broken, not as
    /// "not configured". `path` is injectable for testing.
    func loadConfigStrict(path: String = AuthManager.configPath) throws -> AuthConfig? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        do {
            return try JSONDecoder().decode(AuthConfig.self, from: data)
        } catch {
            throw AuthError.configCorrupt("\(error)")
        }
    }

    /// Write `data` to `path` with owner-only permissions (file 0600, dir
    /// 0700). These are credentials — the MusicKit signing key, the user
    /// token — so nobody else on the machine should read them, and they
    /// shouldn't land in backups in the clear with group/other bits set.
    /// The dir is tightened even if it already exists, since
    /// `createDirectory` only sets the mode when it creates.
    static func writeSecure(_ data: Data, to path: String) throws {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    func saveConfig(_ config: AuthConfig, to path: String = AuthManager.configPath) throws {
        let data = try JSONEncoder().encode(config)
        try AuthManager.writeSecure(data, to: path)
    }

    func developerToken() throws -> String {
        guard let config = try loadConfigStrict() else { throw AuthError.configNotFound }
        let keyFullPath = NSString(string: config.keyPath).expandingTildeInPath
        let generator = JWTGenerator(keyID: config.keyId, teamID: config.teamId, keyPath: keyFullPath)
        return try generator.generate()
    }

    func userToken() -> String? {
        guard let data = FileManager.default.contents(atPath: Self.userTokenPath),
              let token = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func saveUserToken(_ token: String, to path: String = AuthManager.userTokenPath) throws {
        guard let data = token.data(using: .utf8) else { return }
        try AuthManager.writeSecure(data, to: path)
    }

    func requireDeveloperToken() throws -> String {
        guard try loadConfigStrict() != nil else {
            throw AuthError.configNotFound
        }
        return try developerToken()
    }

    func requireUserToken() throws -> String {
        guard let token = userToken() else {
            throw AuthError.userTokenRequired
        }
        return token
    }

    func storefront() -> String {
        loadConfig()?.storefront ?? "us"
    }
}
