import Foundation
import CryptoKit

struct JWTGenerator {
    let keyID: String
    let teamID: String
    let keyPath: String

    func generate() throws -> String {
        let keyData = try String(contentsOfFile: keyPath, encoding: .utf8)
        let pemContent = keyData
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")

        guard let keyBytes = Data(base64Encoded: pemContent) else {
            throw AuthError.invalidKeyData
        }

        let privateKey = try P256.Signing.PrivateKey(derRepresentation: keyBytes)

        let now = Int(Date().timeIntervalSince1970)
        let expiry = now + (60 * 60 * 24 * 180) // 180 days

        let header: [String: Any] = ["alg": "ES256", "kid": keyID]
        let payload: [String: Any] = ["iss": teamID, "iat": now, "exp": expiry]

        let headerData = try JSONSerialization.data(withJSONObject: header)
        let payloadData = try JSONSerialization.data(withJSONObject: payload)

        let signingInput = base64URLEncode(headerData) + "." + base64URLEncode(payloadData)
        let signature = try privateKey.signature(for: Data(signingInput.utf8))

        return signingInput + "." + base64URLEncode(signature.rawRepresentation)
    }

    private func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum AuthError: Error, LocalizedError {
    case invalidKeyData
    case configNotFound
    case developerTokenFailed
    case userTokenRequired
    case userTokenExpired(Int)

    var errorDescription: String? {
        switch self {
        case .invalidKeyData: return "Invalid .p8 key data"
        case .configNotFound: return "Config not found at ~/.config/music/config.json — Run: music auth setup"
        case .developerTokenFailed: return "Failed to generate developer token"
        case .userTokenRequired: return "This command requires Apple Music authorization. Run: music auth"
        case .userTokenExpired(let status): return "User token expired or invalid (status \(status)). Run: music auth"
        }
    }
}
