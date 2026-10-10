import XCTest
@testable import Workdeck

/// 契约夹具适配：contract/fixtures/*.json 作为测试 bundle 资源（project.yml 里挂进 WorkdeckTests）。
final class ContractFixturesTests: XCTestCase {
    private func fixture(_ name: String) throws -> [String: Any] {
        let url = Bundle(for: Self.self).resourceURL!.appendingPathComponent("fixtures/\(name).json")
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    private func cases(_ name: String) throws -> [[String: Any]] { try fixture(name)["cases"] as! [[String: Any]] }
    private func state(_ s: String) -> TransferState { TransferState(rawValue: s)! }
    /// billing.json 不是 `{cases:[...]}` 结构，是按段名（balance/recharge/status/envelope）
    /// 各自一个数组，取段名而不是 "cases"。
    private func billingSection(_ key: String) throws -> [[String: Any]] { try fixture("billing")[key] as! [[String: Any]] }

    func testTally() throws {
        for k in try cases("tally") {
            let items = (k["states"] as! [String]).map { TestItems.make(state($0)) }
            let t = TransferTally.of(items)
            let e = k["expect"] as! [String: Int]
            XCTAssertEqual(t.uploading, e["uploading"], k["name"] as! String)
            XCTAssertEqual(t.failed, e["failed"], k["name"] as! String)
            XCTAssertEqual(t.staged, e["staged"], k["name"] as! String)
            XCTAssertEqual(t.landed, e["landed"], k["name"] as! String)
            XCTAssertEqual(t.total, e["total"], k["name"] as! String)
        }
    }

    func testTransitions() throws {
        for k in try cases("transitions") {
            let from = state(k["from"] as! String)
            let ev = TransferEvent(rawValue: k["event"] as! String)!
            let got = from.next(ev, attempts: k["attempts"] as! Int)
            let want = (k["to"] as? String).map(state)
            XCTAssertEqual(got, want, "\(from)+\(ev)(\(k["attempts"]!))")
        }
    }

    func testRestore() throws {
        for k in try cases("restore") {
            XCTAssertEqual(state(k["state"] as! String).recovered(attempts: k["attempts"] as! Int), state(k["expect"] as! String))
        }
    }

    func testStatusMerge() throws {
        for k in try cases("status-merge") {
            let st = k["status"] as! [String: Any]
            let got = state(k["state"] as! String).applyingStatus(
                delivered: st["delivered"] as! Bool,
                waitingSeconds: Int64(st["waitingSeconds"] as! Int),
                expiresAt: st["expiresAt"] as? String)
            let e = k["expect"] as! [String: Any]
            XCTAssertEqual(got.state, state(e["state"] as! String), k["name"] as! String)
            XCTAssertEqual(got.waitingSeconds, (e["waitingSeconds"] as? Int).map(Int64.init), k["name"] as! String)
            XCTAssertEqual(got.expiresAt, e["expiresAt"] as? String, k["name"] as! String)
        }
    }

    func testDeleteWarning() throws {
        for k in try cases("delete-warning") {
            let got = LibraryGrouping.deleteWarningLevel((k["states"] as! [String]).map(state))
            let e = k["expect"] as! [String: Any]
            XCTAssertEqual(got.level, e["level"] as! String)
            XCTAssertEqual(got.n, e["n"] as! Int)
        }
    }

    func testLegacyMovingDecodes() throws {
        let decoded = try JSONDecoder().decode([TransferState].self, from: Data(#"["moving","waiting"]"#.utf8))
        XCTAssertEqual(decoded, [.uploading, .waiting])
        let encoded = String(data: try JSONEncoder().encode([TransferState.uploading]), encoding: .utf8)
        XCTAssertEqual(encoded, #"["uploading"]"#)
    }

    func testStringsComeFromContract() {
        XCTAssertEqual(TransferPhase.landed.caption, tr("phase.landed"))
        XCTAssertEqual(TransferState.failed.caption, "上传失败")
        XCTAssertEqual(tr("delete.title", ["n": "3"]), "删除 3 件")
    }

    /// billing.json 的 envelope 段（dev-board#425）：kind 是机器可读判别位，一律按它分支，
    /// 不匹配 message 措辞。缺席的 kind/outTradeNo 必须解成 nil，不是空串；八个 kind
    /// 全部取值都要能解码，一个不缺。
    func testBillingEnvelopeFixtures() throws {
        struct Envelope: Decodable {
            let code: Int
            let message: String?
            let kind: API.BillingKind?
            let outTradeNo: String?
        }
        var seenKinds = Set<String>()
        for k in try billingSection("envelope") {
            let name = k["name"] as! String
            let json = k["json"] as! [String: Any]
            let expect = k["expect"] as! [String: Any]
            let data = try JSONSerialization.data(withJSONObject: json)
            let env = try JSONDecoder().decode(Envelope.self, from: data)
            XCTAssertEqual(env.code, expect["code"] as! Int, name)
            XCTAssertEqual(env.message, expect["message"] as? String, name)
            XCTAssertEqual(env.kind?.rawValue, expect["kind"] as? String, name)
            XCTAssertEqual(env.outTradeNo, expect["outTradeNo"] as? String, name)
            // 键缺席要解成 nil；尤其 outTradeNo 不能被误当成「读到了一个空单号」。
            XCTAssertNotEqual(env.outTradeNo, "", name)
            if let kind = env.kind { seenKinds.insert(kind.rawValue) }
        }
        XCTAssertEqual(seenKinds, Set(API.BillingKind.allCases.map(\.rawValue)),
                       "夹具必须覆盖全部八个 kind")
    }

    /// billing.json 的 balance 段：plan 是计费档位（paid/free/null），不是套餐名。
    /// SettingsView.balanceCaption 只读 balanceCents/currency 拼格式化金额，从不读 plan——
    /// 这里断言解码正确即可，plan 是否被渲染由那处代码本身保证（它压根没有 plan 这个入参）。
    func testBillingBalanceFixtures() throws {
        for k in try billingSection("balance") {
            let name = k["name"] as! String
            let json = k["json"] as! [String: Any]
            let expect = k["expect"] as! [String: Any]
            let data = try JSONSerialization.data(withJSONObject: json)
            let balance = try JSONDecoder().decode(API.BillingBalance.self, from: data)
            XCTAssertEqual(balance.balanceCents, Int64(expect["balanceCents"] as! Int), name)
            XCTAssertEqual(balance.currency, expect["currency"] as! String, name)
            XCTAssertEqual(balance.plan, expect["plan"] as? String, name)
        }
    }

    /// billing.json 的 balance 段驱动 `API.decodeBillingBalance`——这是 `API.billingBalance()`
    /// 真正在用的判读函数，覆盖裸对象分支（二轮复审 N4：以前这段判读代码一行测试都没有覆盖过，
    /// 见 Backend.swift 上 `decodeBillingBalance` 的注释）。
    func testSubscriptionAllowanceAndUnknownPersistentQuotaStaySeparateFromCash() throws {
        let data = Data(#"{"balanceCents":0,"currency":"CNY","plan":"paid","subscription":{"active":true,"availableCents":2500,"monthlyLimitCents":14900,"monthlyUsedCents":2000,"weeklyLimitCents":4500,"weeklyUsedCents":2000}}"#.utf8)
        guard case .ok(let balance) = API.decodeBillingBalance(status: 200, data: data) else {
            return XCTFail("subscription response must decode")
        }
        XCTAssertEqual(balance.balanceCents, 0)
        XCTAssertEqual(balance.subscription?.availableCents, 2500)
        XCTAssertEqual(balance.subscription?.monthlyLimitCents, 14900)
        let usage = try JSONDecoder().decode(API.MediaUsage.self, from: Data(#"{"usedBytes":9,"quotaBytes":209715200,"persistentUsedBytes":42,"persistentQuotaBytes":null,"persistentQuotaAvailable":false}"#.utf8))
        XCTAssertEqual(usage.usedBytes, 9)
        XCTAssertEqual(usage.persistentUsedBytes, 42)
        XCTAssertNil(usage.persistentQuotaBytes)
        XCTAssertEqual(usage.persistentQuotaAvailable, false)
    }

    func testBillingBalanceDecodeFixtures() throws {
        for k in try billingSection("balance") {
            let name = k["name"] as! String
            let json = k["json"] as! [String: Any]
            let expect = k["expect"] as! [String: Any]
            let data = try JSONSerialization.data(withJSONObject: json)
            guard case .ok(let balance) = API.decodeBillingBalance(status: 200, data: data) else {
                XCTFail("\(name)：期望 .ok"); continue
            }
            XCTAssertEqual(balance.balanceCents, Int64(expect["balanceCents"] as! Int), name)
            XCTAssertEqual(balance.currency, expect["currency"] as! String, name)
            XCTAssertEqual(balance.plan, expect["plan"] as? String, name)
        }
    }

    /// billing.json 的 envelope 段驱动同一条生产判读路径，钉住 UI 映射表（唯一来源见
    /// contract/schema/billing.schema.json，与小程序 utils/money.ts 的 balanceRowForError 逐条对齐）：
    /// DISABLED / REVIEW_ACCOUNT 整行不渲染、入口一并收起；NOT_CONNECTED 在有支付通道的端
    /// （iOS = iap）显示余额行 + balance.notConnected + **充值入口照常可见**（dev-board#535）；
    /// 其余（含 kind 缺席）显示 balance.unavailable 而入口保持可见。
    /// 把 `balanceRowPlan` 的任何一条改坏，这里必须变红——这就是这份测试存在的意义。
    func testBillingBalanceKindMappingFixtures() throws {
        for k in try billingSection("envelope") {
            let name = k["name"] as! String
            let json = k["json"] as! [String: Any]
            let kindText = json["kind"] as? String
            // ALREADY_PAID / IDEMPOTENCY_CONFLICT 只出现在下单/查单路径，走不到余额端点。
            if kindText == "ALREADY_PAID" || kindText == "IDEMPOTENCY_CONFLICT" { continue }
            let data = try JSONSerialization.data(withJSONObject: json)
            guard case .failed(let kind) = API.decodeBillingBalance(status: 200, data: data) else {
                XCTFail("\(name)：失败信封应该解成 .failed"); continue
            }
            XCTAssertEqual(kind?.rawValue, kindText, name)

            let plan = API.balanceRowPlan(kind: kind, canRecharge: true)
            switch kindText {
            case "DISABLED", "REVIEW_ACCOUNT":
                XCTAssertEqual(plan, API.BalanceRowPlan(showRow: false, showRecharge: false, textKey: nil), name)
            case "NOT_CONNECTED":
                XCTAssertEqual(plan, API.BalanceRowPlan(showRow: true, showRecharge: true,
                                                        textKey: "balance.notConnected"), name)
                // 没有支付通道的端仍旧整行不渲染——同一张表的另一半
                XCTAssertEqual(API.balanceRowPlan(kind: kind, canRecharge: false),
                               API.BalanceRowPlan(showRow: false, showRecharge: false, textKey: nil), name)
            default:
                XCTAssertEqual(plan, API.BalanceRowPlan(showRow: true, showRecharge: true,
                                                        textKey: "balance.unavailable"), name)
            }
        }
    }

    /// billing.json 的 recharge 段驱动生产解码路径 `API.decodeRechargeOrder`（dev-board#426）：
    /// 缺席的可选键一律解成 nil、**不是空串**；present=native 的 appAccountToken 必须留住——
    /// 丢了它这笔单与那笔 StoreKit 交易之间就再没有任何挂钩，苹果也没有按它反查的端点。
    func testRechargeOrderDecodeFixtures() throws {
        var presents = Set<String>()
        for k in try billingSection("recharge") {
            let name = k["name"] as! String
            let json = k["json"] as! [String: Any]
            let expect = k["expect"] as! [String: Any]
            let order = try API.decodeRechargeOrder(status: 200,
                                                    data: JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(order.present, expect["present"] as! String, name)
            XCTAssertEqual(order.outTradeNo, expect["outTradeNo"] as! String, name)
            XCTAssertEqual(order.amountCents, expect["amountCents"] as! Int, name)
            XCTAssertEqual(order.codeUrl, expect["codeUrl"] as? String, name)
            XCTAssertEqual(order.qrCode, expect["qrCode"] as? String, name)
            XCTAssertEqual(order.redirectUrl, expect["redirectUrl"] as? String, name)
            XCTAssertEqual(order.signData, expect["signData"] as? String, name)
            XCTAssertEqual(order.paySig, expect["paySig"] as? String, name)
            XCTAssertEqual(order.signature, expect["signature"] as? String, name)
            XCTAssertEqual(order.appAccountToken, expect["appAccountToken"] as? String, name)
            // 键缺席要解成 nil，不能是「读到了一个空值」
            XCTAssertNotEqual(order.appAccountToken, "", name)
            presents.insert(order.present)
        }
        XCTAssertEqual(presents, ["qrcode", "redirect", "virtual", "native"],
                       "四种 present 都要对过：只测 qrcode 发现不了 native 把 appAccountToken 解丢")
    }

    /// billing.json 的 status 段驱动 `API.decodeRechargeStatus`。confirm 与 status 两个端点
    /// 共用这同一个形状（所以契约里 confirm 不另起夹具段），四种状态都要能解。
    func testRechargeStatusDecodeFixtures() throws {
        var seen = Set<String>()
        for k in try billingSection("status") {
            let name = k["name"] as! String
            let json = k["json"] as! [String: Any]
            let expect = k["expect"] as! [String: Any]
            let s = try API.decodeRechargeStatus(status: 200,
                                                 data: JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(s.status, expect["status"] as! String, name)
            XCTAssertEqual(s.paid, expect["paid"] as! Bool, name)
            XCTAssertEqual(s.amountCents, expect["amountCents"] as! Int, name)
            seen.insert(s.status)
        }
        XCTAssertEqual(seen, ["pending", "paid", "closed", "expired"])
    }

    /// 下单/确认路径上的失败信封必须抛成带 kind 的 `API.BillingError`，绝不能被当成成功解码。
    /// ALREADY_PAID / IDEMPOTENCY_CONFLICT 还要把 outTradeNo 带出来——App 被杀、本地没存下单号时
    /// 全靠它恢复。
    func testRechargeEnvelopeFailsWithKindFixtures() throws {
        for k in try billingSection("envelope") {
            let name = k["name"] as! String
            let json = k["json"] as! [String: Any]
            let expect = k["expect"] as! [String: Any]
            let data = try JSONSerialization.data(withJSONObject: json)
            XCTAssertThrowsError(try API.decodeRechargeOrder(status: 200, data: data), name) { error in
                guard let e = error as? API.BillingError else {
                    XCTFail("\(name)：应该抛 API.BillingError"); return
                }
                XCTAssertEqual(e.kind?.rawValue, expect["kind"] as? String, name)
                XCTAssertEqual(e.outTradeNo, expect["outTradeNo"] as? String, name)
                XCTAssertEqual(e.message, expect["message"] as? String, name)
            }
        }
    }

    /// billing.json 的 balance 段还钉住金额展示口径本身（二轮复审 N7）：不带千分位、
    /// 固定两位小数、符号按 currency 取、不跟设备 locale 走。参考实现见
    /// contract/tools/check.mjs 的 referenceMoneyDisplay，check.mjs 已经用它复算过夹具的
    /// display 字段，这里只需要拿 SettingsView.formatAmount 与夹具本身对拍。
    func testBillingAmountDisplayFixtures() throws {
        for k in try billingSection("balance") {
            let name = k["name"] as! String
            let json = k["json"] as! [String: Any]
            let display = k["display"] as! String
            let cents = Int64(json["balanceCents"] as! Int)
            let currency = json["currency"] as! String
            XCTAssertEqual(SettingsView.formatAmount(cents: cents, currency: currency), display, name)
        }
    }

    func testL10nLocaleSwitchesToEnglish() {
        L10n.locale = "en"
        defer { L10n.locale = "zh-Hans" }
        XCTAssertEqual(tr("phase.landed"), "Landed")
    }
}
