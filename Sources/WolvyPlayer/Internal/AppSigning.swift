import CryptoKit
import Foundation

/// The strings and signatures of app protection, exactly as Wolvy's server makes them
/// (Wolvy-Backend's app_protection.php and sdk_app_key.php). The tests check them against values
/// the server's PHP gave.
enum AppSigning {
    /// What the device proves: ties the proof to the server's challenge, the account and the app.
    static func bound(challenge: String, accountId: Int64, platform: String, appId: String) -> String {
        "wolvy-attest|1|\(challenge)|\(accountId)|\(platform)|\(appId)"
    }

    /// App Attest's clientDataHash: SHA-256 of the bound string.
    static func clientDataHash(_ bound: String) -> Data {
        Data(SHA256.hash(data: Data(bound.utf8)))
    }

    /// app_render_video's X-Wolvy-App-Signature. The key is used as text, as the server does.
    static func renderSignature(key: String, videoId: String, accountId: Int64, timestamp: Int64) -> String {
        hmacHex(key: key, message: "\(videoId):\(accountId):\(timestamp)")
    }

    /// The licence servers' X-Wolvy-Licence-Signature: over the SHA-256 (hex) of the licence token.
    static func licenceSignature(key: String, licenceToken: String, timestamp: Int64) -> String {
        hmacHex(key: key, message: hex(Data(SHA256.hash(data: Data(licenceToken.utf8)))) + ":\(timestamp)")
    }

    static func hmacHex(key: String, message: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(key.utf8)))
        return hex(Data(mac))
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}
