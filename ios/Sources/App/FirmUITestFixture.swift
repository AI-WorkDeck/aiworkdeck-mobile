// SPDX-FileCopyrightText: 2026 北京公富信息技术有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
#if DEBUG
import Foundation

/// Debug-only: answers firm portal reads in-process with a fictional firm and synthetic matters, so CI can
/// screenshot the Reviews tab without a portal server. Launch with `-AWDFirmUITest -AWDFirmFixture`.
/// Nothing leaves the device; writes answer `{"ok":true}` and change nothing.
struct FirmUITestFixture: FirmTransport {
    static var isOn: Bool { FirmUITestSeed.isOn && ProcessInfo.processInfo.arguments.contains("-AWDFirmFixture") }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let path = request.url?.path ?? ""
        let body: String
        if path.hasSuffix("/api/portal/me") { body = Self.me }
        else if path.hasSuffix("/api/portal/matters") { body = Self.matters }
        else if path.hasSuffix("/api/portal/matter"), request.httpMethod == "GET" {
            let id = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value
            body = id == "mtr-review" ? Self.review : Self.plain(id ?? "")
        } else if request.httpMethod == "POST" { body = #"{"ok":true,"n":3}"# }
        else { return (Data(#"{"error":"not_found"}"#.utf8), 404) }
        return (Data(body.utf8), 200)
    }

    static let me = #"""
    {"kind":"lawyer","name":"Morgan Lee","status":"approved","scope":"demo",
     "firm":{"en":"Harbor & Pine LLP"},"lawyerName":{"en":"Morgan Lee"},
     "lawyerTitle":{"en":"Partner"},"lawyerOffice":{"en":"Seattle"}}
    """#
    static let matters = #"""
    {"serverTime":"2026-11-26T09:00:00Z","matters":[
     {"id":"mtr-review","status":"review","updatedAt":"2026-11-26T08:10:00Z","template":{"en":"SAFE"},
      "client":"Ada Park","company":"Northwind Robotics","versions":2,"lawyerName":"Morgan Lee","forLawyerCount":2,"attention":"review_requested"},
     {"id":"mtr-call","status":"drafting","updatedAt":"2026-11-26T07:40:00Z","template":{"en":"Mutual NDA"},
      "client":"Leo Grant","company":"Bluefin Studio","versions":1,"lawyerName":"Morgan Lee","attention":"call_requested",
      "consult":{"status":"requested","times":"Thu 10:00–12:00","note":"About the term"}},
     {"id":"mtr-wait","status":"awaiting_client","updatedAt":"2026-11-25T16:20:00Z","template":{"en":"Consulting agreement"},
      "client":"Mia Chen","versions":3,"lawyerName":"Morgan Lee"},
     {"id":"mtr-done","status":"signed","updatedAt":"2026-11-24T11:05:00Z","template":{"en":"Offer letter"},
      "client":"Sam Ortiz","company":"Cedar Labs","versions":2,"lawyerName":"Morgan Lee"}]}
    """#
    static let review = #"""
    {"id":"mtr-review","status":"review","updatedAt":"2026-11-26T08:10:00Z","template":{"en":"SAFE"},
     "client":"Ada Park","company":"Northwind Robotics","lawyerName":"Morgan Lee",
     "transcript":[{"role":"user","content":"Is a $10M post-money cap reasonable for a seed robotics company?","name":"Ada Park","at":"2026-11-26T08:00:00Z","version":2}],
     "versions":[
      {"n":1,"markdown":"# SAFE\n\n## 1. Valuation cap\n\nThe valuation cap is $8M, with no discount.","by":"client"},
      {"n":2,"markdown":"# SAFE\n\n## 1. Valuation cap\n\nThe valuation cap is $10M post-money, with no discount.\n\n## 2. Pro rata\n\nThe investor may join the next priced round pro rata.","by":"client",
       "notes":{"changes":["Raised the valuation cap to $10M"],"flags":[{"id":"f1","level":"high","section":"1","title":"Cap above recent seed comparables","risk":"Dilution for later rounds"}]}}],
     "flagState":{"2":{"f1":"lawyer"}},
     "forLawyer":[{"text":"Is a $10M post-money cap reasonable for a seed robotics company?","section":"1","version":2},
                  {"text":"Should the pro rata right be in a side letter?","section":"2","version":2}]}
    """#
    static func plain(_ id: String) -> String {
        ##"{"id":"\##(id)","status":"awaiting_client","updatedAt":"2026-11-25T16:20:00Z","client":"Mia Chen","transcript":[],"##
            + ###""versions":[{"n":1,"markdown":"# Consulting agreement\n\n## 1. Services\n\nThe consultant advises on product strategy.","by":"lawyer"}]}"###
    }
}
#endif
