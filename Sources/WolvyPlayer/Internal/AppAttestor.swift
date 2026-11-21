import DeviceCheck
import Foundation
import Security

/// An app key from Wolvy: the app proved itself, and signs its requests with it.
struct AppKey: Sendable {
    let accountId: Int64
    let keyId: String
    let key: String
    let expiresAt: Int64
}

/// Apple's App Attest, behind a protocol so the tests can stand in for it.
protocol AppAttestService: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data
}

/// Where the attested key id is kept between launches (one per app install).
protocol AttestKeyStore: Sendable {
    func load() -> String?
    func save(_ keyId: String)
    func delete()
}

/// App protection (SDK plan phase 5): proves this app to Wolvy with Apple's App Attest, and keeps
/// the app key Wolvy gives back. With the key, app_render_video and the FairPlay licence requests
/// are signed, and Wolvy treats the app like Wolvy Player.
///
/// 1. `POST {api}/app_challenge` says how the app proves itself. `method: null` means the account
///    has not set up protection for this app (its team id): the app plays unproven.
/// 2. The first time on this install, a new App Attest key is attested over SHA-256 of
///    ``AppSigning/bound(challenge:accountId:platform:appId:)``; every later time, an assertion
///    with the stored key. `POST {api}/app_attest` checks it and answers the app key (6 hours).
///    Wolvy answering `attest_again` (it does not know the key) starts over with a new key.
///
/// Every failure falls back to unproven and is not tried again for a while. A refusal from Wolvy
/// (a copy signed by another team, a test build) is kept in ``lastRefusal`` so the error shown
/// when the account requires proven apps says why.
actor AppAttestor {
    typealias Post = @Sendable (_ url: URL, _ headers: [String: String], _ form: [(String, String)]) async throws -> (Int, [String: Any])

    private let appId: String
    private let sdk: String
    private let apiBase: URL
    private let service: AppAttestService
    private let store: AttestKeyStore
    private let post: Post
    private let clock: @Sendable () -> Int64

    private var key: AppKey?
    private var waitAccount: Int64 = 0
    private var waitUntil: Int64 = 0
    /// A key Apple could not attest yet (serverUnavailable): Apple says to try it again later.
    private var pendingKeyId: String?
    private(set) var lastRefusal: WolvyError?

    /// Renew the key this long before it ends; how long to play unproven before trying again.
    private static let renewMargin: Int64 = 60
    private static let againNotSetUp: Int64 = 600
    private static let againRefused: Int64 = 600
    private static let againFailed: Int64 = 300
    private static let againNetwork: Int64 = 30

    init(appId: String, sdk: String, apiBase: URL, service: AppAttestService, store: AttestKeyStore,
         post: @escaping Post, clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }) {
        self.appId = appId
        self.sdk = sdk
        self.apiBase = apiBase
        self.service = service
        self.store = store
        self.post = post
        self.clock = clock
    }

    /// A valid app key for `accountId`, or nil to play unproven.
    func keyFor(_ accountId: Int64) async -> AppKey? {
        let now = clock()
        if let key, key.accountId == accountId, key.expiresAt - now > Self.renewMargin { return key }
        if waitAccount == accountId, now < waitUntil { return nil }
        do {
            let k = try await prove(accountId)
            key = k
            lastRefusal = nil
            return k
        } catch let unproven as Unproven {
            key = nil
            waitAccount = accountId
            waitUntil = now + unproven.againAfter
            return nil
        } catch {
            key = nil
            waitAccount = accountId
            waitUntil = now + Self.againFailed
            return nil
        }
    }

    /// Wolvy refused the key (expired or unknown): prove the app again on the next request.
    func invalidate() {
        key = nil
        waitUntil = 0
    }

    func refusal() -> WolvyError? { lastRefusal }

    // MARK: The flow

    private struct Unproven: Error {
        let reason: String
        let againAfter: Int64
    }

    private func prove(_ accountId: Int64) async throws -> AppKey {
        guard service.isSupported else { throw Unproven(reason: "App Attest not supported", againAfter: Self.againNotSetUp) }
        let challenge = try await challenge(accountId)
        if let stored = store.load() {
            let (status, json) = try await send(accountId, challenge: challenge, fields: [
                ("key_id", stored),
                ("assertion", try await assertion(stored, challenge: challenge, accountId: accountId).base64EncodedString()),
            ])
            if status == 409, AppSigning.string(json["code"]) == "attest_again" {
                store.delete()
                return try await attestNewKey(accountId, challenge: try await self.challenge(accountId))
            }
            return try appKey(accountId, status: status, json: json)
        }
        return try await attestNewKey(accountId, challenge: challenge)
    }

    private func attestNewKey(_ accountId: Int64, challenge: String) async throws -> AppKey {
        let keyId: String
        if let pendingKeyId { keyId = pendingKeyId } else {
            do { keyId = try await service.generateKey() } catch {
                throw Unproven(reason: "generateKey failed", againAfter: Self.againFailed)
            }
        }
        let hash = AppSigning.clientDataHash(AppSigning.bound(challenge: challenge, accountId: accountId, platform: "ios", appId: appId))
        let attestation: Data
        do {
            attestation = try await service.attestKey(keyId, clientDataHash: hash)
            pendingKeyId = nil
        } catch let error as DCError where error.code == .serverUnavailable {
            pendingKeyId = keyId // Apple: try again later with the same key
            throw Unproven(reason: "Apple unavailable", againAfter: Self.againNetwork)
        } catch {
            pendingKeyId = nil // Apple: any other error, discard the key
            throw Unproven(reason: "attestKey failed", againAfter: Self.againFailed)
        }
        let (status, json) = try await send(accountId, challenge: challenge, fields: [
            ("key_id", keyId), ("attestation", attestation.base64EncodedString()),
        ])
        let k = try appKey(accountId, status: status, json: json)
        store.save(keyId)
        return k
    }

    private func assertion(_ keyId: String, challenge: String, accountId: Int64) async throws -> Data {
        let hash = AppSigning.clientDataHash(AppSigning.bound(challenge: challenge, accountId: accountId, platform: "ios", appId: appId))
        do {
            return try await service.generateAssertion(keyId, clientDataHash: hash)
        } catch let error as DCError where error.code == .invalidKey {
            store.delete() // the key is gone (reinstall, restore, new device): attest a new one next time
            throw Unproven(reason: "invalid key", againAfter: 0)
        } catch {
            throw Unproven(reason: "generateAssertion failed", againAfter: Self.againFailed)
        }
    }

    private func challenge(_ accountId: Int64) async throws -> String {
        let (status, json) = try await call("app_challenge", [("user_id", String(accountId))])
        guard AppSigning.string(json["status"]) == "success" else {
            throw Unproven(reason: "app_challenge \(status)", againAfter: status == 429 || status >= 500 ? Self.againNetwork : Self.againNotSetUp)
        }
        guard AppSigning.string(json["method"]) == "app_attest" else {
            throw Unproven(reason: "not set up", againAfter: Self.againNotSetUp)
        }
        guard let challenge = AppSigning.string(json["challenge"]),
              challenge.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw Unproven(reason: "bad challenge", againAfter: Self.againFailed)
        }
        return challenge
    }

    private func send(_ accountId: Int64, challenge: String, fields: [(String, String)]) async throws -> (Int, [String: Any]) {
        try await call("app_attest", [("user_id", String(accountId)), ("challenge", challenge)] + fields)
    }

    private func call(_ endpoint: String, _ form: [(String, String)]) async throws -> (Int, [String: Any]) {
        do {
            return try await post(apiBase.appendingPathComponent(endpoint),
                                  ["X-Wolvy-Platform": "ios", "X-Wolvy-App-Id": appId, "X-Wolvy-SDK": sdk], form)
        } catch {
            throw Unproven(reason: "\(endpoint): network", againAfter: Self.againNetwork)
        }
    }

    private func appKey(_ accountId: Int64, status: Int, json: [String: Any]) throws -> AppKey {
        if AppSigning.string(json["status"]) == "success",
           let keyId = AppSigning.string(json["key_id"]), !keyId.isEmpty,
           let value = AppSigning.string(json["key"]), !value.isEmpty,
           let exp = (json["expires_at"] as? NSNumber)?.int64Value, exp > 0 {
            return AppKey(accountId: accountId, keyId: keyId, key: value, expiresAt: exp)
        }
        let code = AppSigning.string(json["code"]) ?? "http_\(status)"
        if ["device_compromised", "app_not_genuine", "attestation_failed"].contains(code) {
            lastRefusal = WolvyError(.playbackError, AppSigning.string(json["message"]) ?? "This app couldn't verify itself.", reason: code)
        }
        throw Unproven(reason: "app_attest: \(code)", againAfter: code == "attestation_failed" ? Self.againNetwork : Self.againRefused)
    }
}

extension AppSigning {
    static func string(_ value: Any?) -> String? { WolvyPlaybackData.string(value) }
}

// MARK: The real services

/// Apple's DCAppAttestService.
struct AppleAppAttest: AppAttestService {
    var isSupported: Bool { DCAppAttestService.shared.isSupported }
    func generateKey() async throws -> String { try await DCAppAttestService.shared.generateKey() }
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.attestKey(keyId, clientDataHash: clientDataHash)
    }
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: clientDataHash)
    }
}

/// The key id in the Keychain: this device only, not in backups (App Attest keys do not survive
/// a restore or a move to another device anyway).
struct KeychainAttestKeyStore: AttestKeyStore {
    let appId: String
    private var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: "net.wolvy.player.app-attest", kSecAttrAccount: appId]
    }

    func load() -> String? {
        var result: CFTypeRef?
        var q = query
        q[kSecReturnData] = true
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ keyId: String) {
        delete()
        var q = query
        q[kSecValueData] = Data(keyId.utf8)
        q[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    func delete() { SecItemDelete(query as CFDictionary) }
}

/// One form POST to Wolvy, answering the status and the JSON object.
func wolvyPostForm(session: URLSession) -> AppAttestor.Post {
    { url, headers, form in
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpBody = form.map { "\($0.0)=\(WolvyPlaybackData.encode($0.1))" }.joined(separator: "&").data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
    }
}
