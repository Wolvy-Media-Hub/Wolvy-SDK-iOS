import DeviceCheck
import XCTest
@testable import WolvyPlayer

/// App protection: the signatures (against values from the server's PHP) and the attestor's flow.
final class AppSigningTests: XCTestCase {
    private let key = "4f2c0d5e6a7b8c9d0e1f2a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f"

    func testBoundMatchesTheServer() {
        XCTAssertEqual(AppSigning.bound(challenge: "00e1", accountId: 29, platform: "ios", appId: "net.wolvy.spike.attest"),
                       "wolvy-attest|1|00e1|29|ios|net.wolvy.spike.attest")
        // php: wolvy_aa_client_data_hash(...) is SHA-256 of the bound string
        XCTAssertEqual(AppSigning.hex(AppSigning.clientDataHash("abc")),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testSignaturesMatchTheServer() {
        // php: hash_hmac('sha256', 'vidA1:29:1795288000', $key)
        XCTAssertEqual(AppSigning.renderSignature(key: key, videoId: "vidA1", accountId: 29, timestamp: 1_795_288_000),
                       "72670584018c58a96a37b00480d2717ffedfba4990a623617fcf28276c20e573")
        // php: hash_hmac('sha256', hash('sha256', 'aaa.bbb.ccc') . ':1795288000', $key)
        XCTAssertEqual(AppSigning.licenceSignature(key: key, licenceToken: "aaa.bbb.ccc", timestamp: 1_795_288_000),
                       "c6792382fc0faccd2fc64b46a4bb5d1a3f3495047d63d3e900876d9225f4a2a6")
    }
}

/// Stand-ins for Apple's service, the Keychain and Wolvy.
final class FakeAttest: AppAttestService, @unchecked Sendable {
    var isSupported = true
    var keys = 0
    var attested: [(String, Data)] = []
    var asserted: [(String, Data)] = []
    var attestError: Error?
    var assertError: Error?
    func generateKey() async throws -> String { keys += 1; return Data(repeating: UInt8(keys), count: 32).base64EncodedString() }
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        if let attestError { self.attestError = nil; throw attestError }
        attested.append((keyId, clientDataHash)); return Data("attestation".utf8)
    }
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        if let assertError { throw assertError }
        asserted.append((keyId, clientDataHash)); return Data("assertion".utf8)
    }
}

final class MemoryStore: AttestKeyStore, @unchecked Sendable {
    var keyId: String?
    func load() -> String? { keyId }
    func save(_ keyId: String) { self.keyId = keyId }
    func delete() { keyId = nil }
}

final class FakeWolvy: @unchecked Sendable {
    var answers: [(Int, [String: Any])] = []
    var calls: [(String, [String: String])] = []
    var now: Int64 = 1_795_288_000
    static let challenge = String(repeating: "a", count: 64)
    static let setUp: (Int, [String: Any]) = (200, ["status": "success", "method": "app_attest", "challenge": challenge])
    static func key(_ k: String) -> (Int, [String: Any]) {
        (200, ["status": "success", "key_id": "3.1795309600.\(String(repeating: "b", count: 32))", "key": k, "expires_at": 1_795_309_600])
    }

    func attestor(_ service: FakeAttest, _ store: MemoryStore) -> AppAttestor {
        AppAttestor(appId: "net.wolvy.test", sdk: "wolvy-ios/0.2.0", apiBase: URL(string: "https://wolvy.net/api")!,
                    service: service, store: store,
                    post: { url, headers, form in
                        XCTAssertEqual(headers["X-Wolvy-Platform"], "ios")
                        self.calls.append((url.lastPathComponent, Dictionary(form, uniquingKeysWith: { a, _ in a })))
                        guard !self.answers.isEmpty else { throw URLError(.notConnectedToInternet) }
                        return self.answers.removeFirst()
                    },
                    clock: { self.now })
    }
}

final class AppAttestorTests: XCTestCase {
    func testFirstTimeAttestsANewKeyAndKeepsIt() async {
        let wolvy = FakeWolvy(), service = FakeAttest(), store = MemoryStore()
        wolvy.answers = [FakeWolvy.setUp, FakeWolvy.key("k1")]
        let a = wolvy.attestor(service, store)
        let k = await a.keyFor(33)
        XCTAssertEqual(k?.key, "k1")
        XCTAssertEqual(wolvy.calls.map(\.0), ["app_challenge", "app_attest"])
        XCTAssertEqual(wolvy.calls[1].1["attestation"], Data("attestation".utf8).base64EncodedString())
        XCTAssertEqual(store.keyId, service.attested.first?.0)
        // The proof is over SHA-256 of the bound string for this challenge, account and app.
        XCTAssertEqual(service.attested.first?.1,
                       AppSigning.clientDataHash(AppSigning.bound(challenge: FakeWolvy.challenge, accountId: 33, platform: "ios", appId: "net.wolvy.test")))
        wolvy.now += 21_000
        let again = await a.keyFor(33)
        XCTAssertEqual(again?.key, "k1")
        XCTAssertEqual(wolvy.calls.count, 2) // kept until a minute before it ends
    }

    func testLaterTimesSendAnAssertionWithTheStoredKey() async {
        let wolvy = FakeWolvy(), service = FakeAttest(), store = MemoryStore()
        store.keyId = "stored-key"
        wolvy.answers = [FakeWolvy.setUp, FakeWolvy.key("k2")]
        let k = await wolvy.attestor(service, store).keyFor(33)
        XCTAssertEqual(k?.key, "k2")
        XCTAssertEqual(service.asserted.first?.0, "stored-key")
        XCTAssertEqual(wolvy.calls[1].1["key_id"], "stored-key")
        XCTAssertNotNil(wolvy.calls[1].1["assertion"])
        XCTAssertTrue(service.attested.isEmpty)
    }

    func testAnUnknownKeyStartsOverWithANewOne() async {
        let wolvy = FakeWolvy(), service = FakeAttest(), store = MemoryStore()
        store.keyId = "old-key"
        wolvy.answers = [FakeWolvy.setUp, (409, ["status": "error", "code": "attest_again"]), FakeWolvy.setUp, FakeWolvy.key("k3")]
        let k = await wolvy.attestor(service, store).keyFor(33)
        XCTAssertEqual(k?.key, "k3")
        XCTAssertEqual(wolvy.calls.map(\.0), ["app_challenge", "app_attest", "app_challenge", "app_attest"])
        XCTAssertNotEqual(store.keyId, "old-key")
        XCTAssertEqual(store.keyId, service.attested.first?.0)
    }

    func testNotSetUpPlaysUnprovenAndWaits() async {
        let wolvy = FakeWolvy(), service = FakeAttest(), store = MemoryStore()
        wolvy.answers = [(200, ["status": "success", "method": NSNull()])]
        let a = wolvy.attestor(service, store)
        let first = await a.keyFor(33)
        let second = await a.keyFor(33)
        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(wolvy.calls.count, 1)
        XCTAssertEqual(service.keys, 0)
    }

    func testARefusalIsKeptForTheError() async {
        let wolvy = FakeWolvy(), service = FakeAttest(), store = MemoryStore()
        wolvy.answers = [FakeWolvy.setUp, (403, ["status": "error", "code": "app_not_genuine", "message": "This copy of the app can't be verified."])]
        let a = wolvy.attestor(service, store)
        let k = await a.keyFor(33)
        XCTAssertNil(k)
        let refusal = await a.refusal()
        XCTAssertEqual(refusal?.reason, "app_not_genuine")
        XCTAssertNil(store.keyId) // a refused key is not kept
    }

    func testAppleUnavailableKeepsTheKeyForTheNextTry() async {
        let wolvy = FakeWolvy(), service = FakeAttest(), store = MemoryStore()
        service.attestError = DCError(.serverUnavailable)
        wolvy.answers = [FakeWolvy.setUp]
        let a = wolvy.attestor(service, store)
        let first = await a.keyFor(33)
        XCTAssertNil(first)
        wolvy.now += 31
        wolvy.answers = [FakeWolvy.setUp, FakeWolvy.key("k4")]
        let second = await a.keyFor(33)
        XCTAssertEqual(second?.key, "k4")
        XCTAssertEqual(service.keys, 1) // the same key, attested on the second try
    }

    func testNoAppAttestOnThisDevice() async {
        let wolvy = FakeWolvy(), service = FakeAttest(), store = MemoryStore()
        service.isSupported = false
        let k = await wolvy.attestor(service, store).keyFor(33)
        XCTAssertNil(k)
        XCTAssertTrue(wolvy.calls.isEmpty)
    }
}

final class ProvenSourceTests: XCTestCase {
    private func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    private func provenSource() -> WolvyAppRenderVideoSource {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let wolvy = FakeWolvy()
        wolvy.answers = [FakeWolvy.setUp, FakeWolvy.key("appkey")]
        return WolvyAppRenderVideoSource(appId: "net.wolvy.test", sdk: "wolvy-ios/0.2.0", apiBase: URL(string: "https://wolvy.net/api")!,
                                         session: URLSession(configuration: config), attestor: wolvy.attestor(FakeAttest(), MemoryStore()),
                                         clock: { 1_795_288_000 })
    }

    func testAProvenAppSignsTheRequestAndTheLicence() async throws {
        var answer = sampleAnswer
        answer["attested"] = true
        StubProtocol.handler = { _ in (200, self.json(answer)) }
        let video = try WolvyVideo(videoId: "vid_1", accountId: 33, viewerToken: "vt")
        let data = try await provenSource().fetch(video: video, sessionId: nil)
        let request = try XCTUnwrap(StubProtocol.lastRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Wolvy-App-Key-Id"), "3.1795309600.\(String(repeating: "b", count: 32))")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Wolvy-App-Timestamp"), "1795288000")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Wolvy-App-Signature"),
                       AppSigning.renderSignature(key: "appkey", videoId: "vid_1", accountId: 33, timestamp: 1_795_288_000))
        XCTAssertTrue(data.attested)
        XCTAssertEqual(data.licenceHeaders(), [
            "X-Wolvy-Licence-Timestamp": "1795288000",
            "X-Wolvy-Licence-Signature": AppSigning.licenceSignature(key: "appkey", licenceToken: data.licenceToken, timestamp: 1_795_288_000),
        ])
    }

    func testAnUnprovenAnswerGetsNoLicenceSignature() async throws {
        StubProtocol.handler = { _ in (200, self.json(sampleAnswer)) }
        let video = try WolvyVideo(videoId: "vid_1", accountId: 33, viewerToken: "vt")
        let data = try await provenSource().fetch(video: video, sessionId: nil)
        XCTAssertFalse(data.attested)
        XCTAssertEqual(data.licenceHeaders(), [:])
    }
}
