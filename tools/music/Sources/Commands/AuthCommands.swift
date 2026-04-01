import ArgumentParser
import Foundation

struct Auth: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage Apple Music authentication.",
        subcommands: [AuthSetup.self, AuthStatus.self, AuthSetToken.self, AuthOpen.self],
        defaultSubcommand: AuthOpen.self
    )
}

struct AuthOpen: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "open", abstract: "Open browser for user token auth.")
    func run() throws {
        let auth = AuthManager()
        let token = try auth.requireDeveloperToken()
        let page = AuthPage()
        try page.serve(developerToken: token)
    }
}

struct AuthSetToken: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set-token", abstract: "Save your Music User Token.")
    @Argument(help: "The Music User Token from the auth page") var token: String
    func run() throws {
        let auth = AuthManager()
        try auth.saveUserToken(token)

        let devToken = try auth.requireDeveloperToken()
        let storefront = auth.storefront()
        let (_, status) = try syncRun {
            try await RESTAPIBackend(developerToken: devToken, userToken: token, storefront: storefront)
                .get("/v1/me/storefront")
        }
        if (200...299).contains(status) {
            print("Token saved and verified.")
        } else {
            print("Token saved but verification failed (status \(status)). May be invalid or expired.")
        }
    }
}

struct AuthStatus: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Check auth status.")
    @Flag(name: .long, help: "Output JSON") var json = false
    func run() throws {
        let auth = AuthManager()
        let hasConfig = auth.loadConfig() != nil
        let hasUserToken = auth.userToken() != nil
        var devTokenWorks = false

        if hasConfig {
            devTokenWorks = (try? auth.developerToken()) != nil
        }

        if json {
            let dict: [String: Any] = [
                "configured": hasConfig,
                "developerToken": devTokenWorks,
                "userToken": hasUserToken,
            ]
            let output = OutputFormat(mode: .json)
            print(output.render(dict))
        } else {
            print("Config: \(hasConfig ? "✓" : "✗ Run: music auth setup")")
            print("Developer token: \(devTokenWorks ? "✓" : "✗")")
            print("User token: \(hasUserToken ? "✓" : "✗ Run: music auth")")
        }
    }
}

struct AuthSetup: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "setup", abstract: "Guided auth setup.")
    func run() throws {
        print("Apple Music CLI Setup")
        print("============================")
        print("")
        print("You need a MusicKit key from developer.apple.com")
        print("")

        print("Key ID (10 characters, from the key details page):")
        guard let keyID = readLine()?.trimmingCharacters(in: .whitespaces), !keyID.isEmpty else {
            print("Aborted.")
            throw ExitCode.failure
        }

        print("Team ID (10 characters, from Membership page):")
        guard let teamID = readLine()?.trimmingCharacters(in: .whitespaces), !teamID.isEmpty else {
            print("Aborted.")
            throw ExitCode.failure
        }

        print("Path to .p8 key file (e.g. ~/Downloads/AuthKey_\(keyID).p8):")
        guard let keyPathInput = readLine()?.trimmingCharacters(in: .whitespaces), !keyPathInput.isEmpty else {
            print("Aborted.")
            throw ExitCode.failure
        }

        let expandedPath = NSString(string: keyPathInput).expandingTildeInPath
        let destPath = "\(AuthManager.configDir)/AuthKey.p8"
        try FileManager.default.createDirectory(atPath: AuthManager.configDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destPath) {
            try FileManager.default.removeItem(atPath: destPath)
        }
        try FileManager.default.copyItem(atPath: expandedPath, toPath: destPath)

        let config = AuthConfig(
            keyId: keyID,
            teamId: teamID,
            keyPath: "~/.config/music/AuthKey.p8",
            storefront: "us"
        )
        let auth = AuthManager()
        try auth.saveConfig(config)

        let _ = try auth.developerToken()
        print("")
        print("✓ Config saved. Developer token generated.")
        print("")
        print("Next: Run `music auth` to open the browser and get your user token.")
    }
}
