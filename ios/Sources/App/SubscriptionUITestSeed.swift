// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
#if DEBUG
import Foundation

/// Local StoreKit UI checks never send their synthetic session or transactions to a server.
enum SubscriptionUITestSeed {
    static let isOn = ProcessInfo.processInfo.arguments.contains("-AWDSubscriptionUITest")
    static let accountToken = "16730000-0000-4000-8000-000000000001"
    static let missingProduct = ProcessInfo.processInfo.arguments.contains("-AWDSubscriptionMissingProduct")
}
final class SubscriptionUITestProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let product = ContractProducts.appstoreSubscriptions[0].productId
        let value: [String: Any]
        if path.hasSuffix("/subscription/appstore/capability") {
            value = ["available": true, "productId": product]
        } else if path.hasSuffix("/subscription/appstore/prepare") {
            value = ["productId": product, "appAccountToken": SubscriptionUITestSeed.accountToken]
        } else if path.hasSuffix("/subscription/appstore/confirm") {
            var bytes = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let n = stream.read(&buffer, maxLength: buffer.count)
                    if n <= 0 { break }
                    bytes.append(buffer, count: n)
                }
            }
            let body = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
            let parts = (body?["signedTransaction"] as? String)?.split(separator: ".") ?? []
            var encoded = parts.count == 3 ? String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") : ""
            encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
            let data = Data(base64Encoded: encoded) ?? Data()
            let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            guard payload?["productId"] as? String == product,
                  (payload?["appAccountToken"] as? String)?.lowercased() == SubscriptionUITestSeed.accountToken,
                  payload?["type"] as? String == "Auto-Renewable Subscription" else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
            }
            value = ["status": ProcessInfo.processInfo.arguments.contains("-AWDSubscriptionConfirmFailure") ? "PENDING" : "CONFIRMED"]
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: value))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
