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

    func saveConfig(_ config: AuthConfig) throws {
        try FileManager.default.createDirectory(atPath: Self.configDir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(config)
        try data.write(to: URL(fileURLWithPath: Self.configPath))
    }

    func developerToken() throws -> String {
        guard let config = loadConfig() else { throw AuthError.configNotFound }
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

    func saveUserToken(_ token: String) throws {
        try FileManager.default.createDirectory(atPath: Self.configDir, withIntermediateDirectories: true)
        try token.write(toFile: Self.userTokenPath, atomically: true, encoding: .utf8)
    }

    func requireDeveloperToken() throws -> String {
        guard loadConfig() != nil else {
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
