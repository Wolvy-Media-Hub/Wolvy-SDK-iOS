import CryptoKit
import DeviceCheck
import Foundation
import Security
import UIKit
import os

/// Phase 5, spike B: App Attest in a customer-like app on a real iPhone (Sauce Labs re-signs it).
///
/// Answers: is App Attest supported there; which team id does the attestation name (RP ID);
/// which environment (aaguid) and launch category; does the nonce sit in the leaf certificate as
/// Apple's server steps say; and how the assertion's signature is to be checked. The raw objects
/// go to the device log in chunks (`WolvyAttest` lines) so the server code can be tested on them.
/// Not the SDK. Nothing is sent anywhere except to Apple by the system.
@MainActor
final class AttestSpike: ObservableObject {
    @Published var lines: [String] = []
    @Published var busy = false

    private let log = Logger(subsystem: "net.wolvy.spike.attest", category: "WolvyAttest")
    private let service = DCAppAttestService.shared
    private let bundleId = Bundle.main.bundleIdentifier ?? "?"
    private let defaults = UserDefaults.standard
    /// Wolvy's own Apple team (Wolvy Player, the FairPlay certificate).
    private let companyTeam = "N858H3328Q"

    init() { describe() }

    // MARK: - What the app runs as

    func describe() {
        lines = []
        add("WolvyAttest spike B, build 1")
        add("iOS \(UIDevice.current.systemVersion), \(Self.model()), app \(bundleId)")
        add("isSupported=\(service.isSupported)")
        add("keychain access group=\(Self.keychainAccessGroup() ?? "none")")
        if let p = Self.provisioningProfile() {
            add("profile name=\(p["Name"] ?? "?")")
            add("profile TeamIdentifier=\(p["TeamIdentifier"] ?? "?") ApplicationIdentifierPrefix=\(p["ApplicationIdentifierPrefix"] ?? "?")")
            add("profile ProvisionsAllDevices=\(p["ProvisionsAllDevices"] ?? "no") devices=\((p["ProvisionedDevices"] as? [Any])?.count ?? 0)")
            if let e = p["Entitlements"] as? [String: Any] {
                add("entitlement application-identifier=\(e["application-identifier"] ?? "?")")
                add("entitlement appattest-environment=\(e["com.apple.developer.devicecheck.appattest-environment"] ?? "none")")
                add("entitlement get-task-allow=\(e["get-task-allow"] ?? "?")")
            }
        } else {
            add("profile=none (no embedded.mobileprovision)")
        }
        add("stored key id=\(defaults.string(forKey: "keyId") ?? "none")")
    }

    // MARK: - Attestation (first time)

    func attest() async {
        busy = true; defer { busy = false }
        add("— attest —")
        guard service.isSupported else { add("App Attest not supported here"); return }
        do {
            let keyId = try await service.generateKey()
            add("generateKey ok, key id=\(keyId)")
            let bound = "wolvy-attest|1|\(Self.randomHex(32))|spike|ios|\(bundleId)"
            let clientDataHash = Data(SHA256.hash(data: Data(bound.utf8)))
            add("bound=\(bound)")
            let attestation = try await service.attestKey(keyId, clientDataHash: clientDataHash)
            add("attestKey ok, \(attestation.count) bytes")
            defaults.set(keyId, forKey: "keyId")
            dump("ATTESTATION", attestation)
            try inspectAttestation(attestation, keyId: keyId, clientDataHash: clientDataHash)
        } catch {
            add("FAILED: \(Self.describe(error))")
        }
    }

    private func inspectAttestation(_ attestation: Data, keyId: String, clientDataHash: Data) throws {
        let (obj, _) = try CBOR.decode(attestation)
        add("fmt=\(obj["fmt"]?.description ?? "?")")
        guard let authData = obj["authData"]?.data else { add("no authData"); return }
        var certs: [Data] = []
        if case .array(let x5c)? = obj["attStmt"]?["x5c"] { certs = x5c.compactMap(\.data) }
        add("x5c: \(certs.count) certificates; receipt \(obj["attStmt"]?["receipt"]?.data?.count ?? 0) bytes")
        for (n, der) in certs.enumerated() {
            if let c = SecCertificateCreateWithData(nil, der as CFData) {
                add("cert \(n): \(SecCertificateCopySubjectSummary(c) as String? ?? "?")")
            }
        }

        let a = try AuthData(authData)
        a.report(into: add)
        // RP ID = SHA256("TEAMID.bundle.id"): which team does it name?
        var candidates = [companyTeam]
        if let g = Self.keychainAccessGroup()?.split(separator: ".").first { candidates.append(String(g)) }
        if let p = Self.provisioningProfile() {
            candidates += (p["TeamIdentifier"] as? [String]) ?? []
            candidates += (p["ApplicationIdentifierPrefix"] as? [String]) ?? []
        }
        var matched = "none of " + Set(candidates).sorted().joined(separator: ", ")
        for team in Set(candidates) where Data(SHA256.hash(data: Data("\(team).\(bundleId)".utf8))) == a.rpIdHash {
            matched = team
        }
        add("RP ID names team: \(matched)")
        add("credentialId = key id: \(a.credentialId == Data(base64Encoded: keyId))")

        // Apple's step 2-4: the nonce must sit in the leaf certificate's extension 1.2.840.113635.100.8.2.
        guard let leaf = certs.first else { return }
        let nonce = Data(SHA256.hash(data: authData + clientDataHash))
        let inCert = Self.nonceExtension(leaf)
        add("nonce in leaf certificate matches: \(inCert == nonce) (cert has \(inCert?.hex ?? "no extension"))")
        // Apple's step 5: SHA256(public key, X9.62 uncompressed) = key id.
        if let c = SecCertificateCreateWithData(nil, leaf as CFData), let key = SecCertificateCopyKey(c),
           let raw = SecKeyCopyExternalRepresentation(key, nil) as Data? {
            add("SHA256(leaf public key) = key id: \(Data(SHA256.hash(data: raw)).base64EncodedString() == keyId)")
            defaults.set(raw, forKey: "publicKey")
        }
    }

    // MARK: - Assertion (every later time)

    func assert() async {
        busy = true; defer { busy = false }
        add("— assert —")
        guard let keyId = defaults.string(forKey: "keyId") else { add("No key yet: attest first"); return }
        do {
            let clientData = Data("wolvy-attest|1|\(Self.randomHex(32))|spike|ios|\(bundleId)".utf8)
            let clientDataHash = Data(SHA256.hash(data: clientData))
            let assertion = try await service.generateAssertion(keyId, clientDataHash: clientDataHash)
            add("generateAssertion ok, \(assertion.count) bytes")
            add("clientData=\(String(decoding: clientData, as: UTF8.self))")
            dump("ASSERTION", assertion)
            let (obj, _) = try CBOR.decode(assertion)
            guard let sig = obj["signature"]?.data, let authData = obj["authenticatorData"]?.data else {
                add("assertion without signature/authenticatorData: \(obj)"); return
            }
            let rp = authData.prefix(32)
            let counter = authData.count >= 37 ? authData[33..<37].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } : 0
            add("assertion counter=\(counter), authenticatorData \(authData.count) bytes")
            add("assertion RP ID = attestation RP ID: \(Data(rp) == (defaults.data(forKey: "rpIdHash") ?? Data()))")
            // Which message does the signature cover? A: authData‖clientDataHash, B: SHA256 of that (the "nonce").
            if let raw = defaults.data(forKey: "publicKey"),
               let key = SecKeyCreateWithData(raw as CFData, [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                                                               kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil) {
                let msgA = authData + clientDataHash
                let msgB = Data(SHA256.hash(data: msgA))
                let okA = SecKeyVerifySignature(key, .ecdsaSignatureMessageX962SHA256, msgA as CFData, sig as CFData, nil)
                let okB = SecKeyVerifySignature(key, .ecdsaSignatureMessageX962SHA256, msgB as CFData, sig as CFData, nil)
                add("signature over authData‖clientDataHash (ECDSA-SHA256): \(okA)")
                add("signature over SHA256(authData‖clientDataHash) (ECDSA-SHA256): \(okB)")
            }
        } catch {
            add("FAILED: \(Self.describe(error))")
        }
    }

    func resetKey() {
        defaults.removeObject(forKey: "keyId"); defaults.removeObject(forKey: "publicKey"); defaults.removeObject(forKey: "rpIdHash")
        add("key forgotten")
    }

    var report: String { lines.joined(separator: "\n") }

    // MARK: - Helpers

    private func add(_ line: String) {
        lines.append(line)
        log.notice("WolvyAttest \(line, privacy: .public)")
    }

    /// Raw objects go to the device log only, in numbered chunks (the log cuts long lines).
    private func dump(_ name: String, _ data: Data) {
        let b64 = data.base64EncodedString()
        let size = 600
        let parts = stride(from: 0, to: b64.count, by: size).map { start -> String in
            let s = b64.index(b64.startIndex, offsetBy: start)
            let e = b64.index(s, offsetBy: min(size, b64.count - start))
            return String(b64[s..<e])
        }
        for (n, part) in parts.enumerated() {
            log.notice("WolvyAttest \(name, privacy: .public) \(n + 1, privacy: .public)/\(parts.count, privacy: .public) \(part, privacy: .public)")
        }
        add("\(name): \(parts.count) chunks in the device log (\(b64.count) base64 characters)")
    }

    struct AuthData {
        let rpIdHash: Data, flags: UInt8, counter: UInt32, aaguid: Data, credentialId: Data
        var extensions: CBOR?

        init(_ d: Data) throws {
            let b = [UInt8](d)
            guard b.count >= 55 else { throw CBOR.Failure.truncated }
            rpIdHash = Data(b[0..<32]); flags = b[32]
            counter = b[33..<37].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            aaguid = Data(b[37..<53])
            let len = Int(b[53]) << 8 | Int(b[54])
            guard b.count >= 55 + len else { throw CBOR.Failure.truncated }
            credentialId = Data(b[55..<(55 + len)])
            // The credential public key (COSE), then the extensions when flag ED (0x80) is set.
            let (_, afterKey) = try CBOR.decode(d, at: 55 + len)
            if flags & 0x80 != 0, afterKey < b.count { extensions = try CBOR.decode(d, at: afterKey).0 }
        }

        func report(into add: (String) -> Void) {
            UserDefaults.standard.set(rpIdHash, forKey: "rpIdHash")
            add("authData flags=0x\(String(format: "%02x", flags)) counter=\(counter)")
            let printable = String(decoding: aaguid.prefix { $0 >= 0x20 && $0 < 0x7f }, as: UTF8.self)
            let env = aaguid == Data("appattest".utf8) + Data(repeating: 0, count: 7) ? "production"
                : aaguid == Data("appattestdevelop".utf8) ? "development" : "unknown"
            add("aaguid=\(printable) (\(aaguid.hex)) → \(env)")
            add("credentialId \(credentialId.count) bytes")
            add("extensions=\(extensions?.description ?? "none")")
        }
    }

    /// The 32-byte octet string inside extension 1.2.840.113635.100.8.2 of the leaf certificate.
    static func nonceExtension(_ der: Data) -> Data? {
        let b = [UInt8](der)
        let oid: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x63, 0x64, 0x08, 0x02]
        guard let at = find(oid, in: b, from: 0) else { return nil }
        let inner: [UInt8] = [0xA1, 0x22, 0x04, 0x20]
        guard let p = find(inner, in: b, from: at + oid.count), p + 4 + 32 <= b.count else { return nil }
        return Data(b[(p + 4)..<(p + 36)])
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8], from: Int) -> Int? {
        guard hay.count >= needle.count else { return nil }
        var i = from
        while i <= hay.count - needle.count {
            if Array(hay[i..<(i + needle.count)]) == needle { return i }
            i += 1
        }
        return nil
    }

    static func keychainAccessGroup() -> String? {
        let base: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrAccount: "wolvy.attest.probe",
                                     kSecAttrService: "wolvy.attest.probe"]
        var result: CFTypeRef?
        var status = SecItemCopyMatching((base.merging([kSecReturnAttributes: true]) { $1 }) as CFDictionary, &result)
        if status == errSecItemNotFound {
            status = SecItemAdd((base.merging([kSecValueData: Data("x".utf8), kSecReturnAttributes: true]) { $1 }) as CFDictionary, &result)
        }
        guard status == errSecSuccess, let attrs = result as? [CFString: Any] else { return "error \(status)" }
        return attrs[kSecAttrAccessGroup] as? String
    }

    static func provisioningProfile() -> [String: Any]? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        let bytes = [UInt8](data)
        guard let start = find(Array("<?xml".utf8), in: bytes, from: 0),
              let end = find(Array("</plist>".utf8), in: bytes, from: start) else { return nil }
        let plist = Data(bytes[start..<(end + 8)])
        return (try? PropertyListSerialization.propertyList(from: plist, format: nil)) as? [String: Any]
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? DCError {
            let name: String
            switch e.code {
            case .featureUnsupported: name = "featureUnsupported"
            case .invalidInput: name = "invalidInput"
            case .invalidKey: name = "invalidKey"
            case .serverUnavailable: name = "serverUnavailable"
            case .unknownSystemFailure: name = "unknownSystemFailure"
            @unknown default: name = "code \(e.code.rawValue)"
            }
            return "DCError.\(name): \(e.localizedDescription)"
        }
        return "\(type(of: error)): \(error.localizedDescription)"
    }

    static func model() -> String {
        var info = utsname(); uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    static func randomHex(_ n: Int) -> String {
        var b = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        return Data(b).hex
    }
}
