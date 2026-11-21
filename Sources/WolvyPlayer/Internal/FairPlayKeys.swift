import AVFoundation

/// Answers FairPlay key requests for one asset, as the spike proved on an iPhone (SDK plan phase 4
/// step 2): the application certificate from `process_videos/fairplay.cer`, the SPC posted to
/// `process_videos/fairplay?token=…` (no Origin: the licence token is an app's, src "sdk"), the CKC
/// handed back to the system. The key address in the playlist is `skd://<videoId>`.
final class FairPlayKeys: NSObject, AVContentKeySessionDelegate {
    /// A licence that could not be had: the HTTP status (0 when the network failed), for the player's error mapping.
    struct Failure {
        let status: Int
        let detail: String
    }

    private static let certificateLock = NSLock()
    private static var certificates: [URL: Data] = [:]

    private let queue = DispatchQueue(label: "net.wolvy.player.fairplay")
    private let session: AVContentKeySession
    private let licenceUrl: URL
    private let certificateUrl: URL
    private let userAgent: String
    private let onFailure: (Failure) -> Void

    init(licenceUrl: URL, certificateUrl: URL, userAgent: String, onFailure: @escaping (Failure) -> Void) {
        self.licenceUrl = licenceUrl
        self.certificateUrl = certificateUrl
        self.userAgent = userAgent
        self.onFailure = onFailure
        session = AVContentKeySession(keySystem: .fairPlayStreaming)
        super.init()
        session.setDelegate(self, queue: queue)
    }

    func attach(_ asset: AVURLAsset) { session.addContentKeyRecipient(asset) }

    // MARK: AVContentKeySessionDelegate

    func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVContentKeyRequest) {
        answer(keyRequest)
    }

    func contentKeySession(_ session: AVContentKeySession, didProvideRenewingContentKeyRequest keyRequest: AVContentKeyRequest) {
        answer(keyRequest)
    }

    func contentKeySession(_ session: AVContentKeySession, shouldRetry keyRequest: AVContentKeyRequest,
                           reason retryReason: AVContentKeyRequest.RetryReason) -> Bool {
        retryReason == .timedOut || retryReason == .receivedResponseWithExpiredLease || retryReason == .receivedObsoleteContentKey
    }

    // MARK: Answering

    static func assetId(fromKeyIdentifier identifier: String) -> String {
        var id = identifier.hasPrefix("skd://") ? String(identifier.dropFirst(6)) : identifier
        if let cut = id.firstIndex(where: { $0 == "?" || $0 == "/" }) { id = String(id[..<cut]) }
        return id
    }

    private func answer(_ keyRequest: AVContentKeyRequest) {
        let identifier = keyRequest.identifier as? String ?? ""
        let assetId = Self.assetId(fromKeyIdentifier: identifier)
        certificate { [self] certificate in
            guard let certificate else {
                fail(keyRequest, Failure(status: 0, detail: "The FairPlay certificate could not be loaded."))
                return
            }
            keyRequest.makeStreamingContentKeyRequestData(forApp: certificate, contentIdentifier: Data(assetId.utf8),
                                                          options: [AVContentKeyRequestProtocolVersionsKey: [1]]) { [self] spc, error in
                guard let spc else {
                    fail(keyRequest, Failure(status: 0, detail: "The key request could not be made: " + (error.map(Scrub.summary) ?? "unknown")))
                    return
                }
                var request = URLRequest(url: licenceUrl, timeoutInterval: 15)
                request.httpMethod = "POST"
                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                request.httpBody = spc
                URLSession.shared.dataTask(with: request) { [self] data, response, error in
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if status == 200, let ckc = data, !ckc.isEmpty {
                        keyRequest.processContentKeyResponse(AVContentKeyResponse(fairPlayStreamingKeyResponseData: ckc))
                    } else {
                        let text = data.flatMap { String(data: $0, encoding: .utf8) }?.prefix(120) ?? ""
                        fail(keyRequest, Failure(status: status, detail: error.map(Scrub.summary) ?? "HTTP \(status) \(text)"))
                    }
                }.resume()
            }
        }
    }

    private func fail(_ keyRequest: AVContentKeyRequest, _ failure: Failure) {
        onFailure(failure)
        keyRequest.processContentKeyResponseError(NSError(domain: "net.wolvy.player.licence", code: failure.status,
                                                          userInfo: [NSLocalizedDescriptionKey: failure.detail]))
    }

    /// The certificate, fetched once per address and kept for the process.
    private func certificate(_ done: @escaping (Data?) -> Void) {
        Self.certificateLock.lock()
        let cached = Self.certificates[certificateUrl]
        Self.certificateLock.unlock()
        if let cached { done(cached); return }
        var request = URLRequest(url: certificateUrl, timeoutInterval: 15)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [certificateUrl] data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let data, !data.isEmpty else { done(nil); return }
            Self.certificateLock.lock()
            Self.certificates[certificateUrl] = data
            Self.certificateLock.unlock()
            done(data)
        }.resume()
    }
}
