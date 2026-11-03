import Foundation
import StoreKit

/// 内购充值的非界面部分（dev-board#426）。三件事：幂等键落盘、把一笔已验签交易送去服务端
/// 确认并在确认成功后 finish、启动时重放未完成交易。
///
/// 顺序的唯一来源是 `docs/specs/2026-09-04-mobile-recharge-design.md` §4：
/// 拿到 `jwsRepresentation` → 发服务端 → 服务端验签并入账成功 → **客户端才 finish**。
/// 未确认前绝不 finish：提前 finish 等于用户付了钱而我们永久失去这笔到账凭据，
/// 苹果不提供按 appAccountToken 反查交易的任何端点（§4.2），补不回来。
enum IAP {
    /// 幂等键落盘的键名。值是 `{key, productId}`：换档位换键，同档位复用。
    private static let storageKey = "awd.recharge.idem"

    private struct PendingIdempotency: Codable {
        let key: String
        let productId: String
    }

    /// 幂等键**生成后先写盘再发请求**：建单途中 App 被杀、重进充值页时同一档位复用同一把键，
    /// 服务端 `UNIQUE(userId, idempotencyKey)` 兜底，不会变成两笔单（与小程序同口径）。
    static func takeIdempotencyKey(productId: String) -> String {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode(PendingIdempotency.self, from: data),
           saved.productId == productId, !saved.key.isEmpty {
            return saved.key
        }
        let pending = PendingIdempotency(key: UUID().uuidString, productId: productId)
        if let data = try? JSONEncoder().encode(pending) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        return pending.key
    }

    static func clearIdempotencyKey() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    /// 送一笔已验签交易去确认。回 true 表示服务端已入账、交易已 finish。
    ///
    /// 任何别的结果（网络失败、REJECTED 验签不过、还在 pending）都**不 finish**：留着让
    /// `Transaction.updates` / `Transaction.unfinished` 下次重放。重放时本地不一定还有单号，
    /// 所以 `outTradeNo` 可省，官网用 JWS 里的 appAccountToken 反查 providerRef。
    @discardableResult
    static func confirm(_ transaction: StoreKit.Transaction, jws: String, outTradeNo: String?) async -> Bool {
        if isSubscription(productId: transaction.productID) {
            guard let confirmation = try? await API.shared.confirmSubscription(signedTransaction: jws),
                  confirmation.confirmed else { return false }
        } else {
            guard ContractProducts.appstore.contains(where: { $0.productId == transaction.productID }),
                  let status = try? await API.shared.billingRechargeConfirm(outTradeNo: outTradeNo, signedTransaction: jws),
                  status.paid else { return false }
        }
        await transaction.finish()
        return true
    }

    static func isSubscription(productId: String) -> Bool {
        ContractProducts.appstoreSubscriptions.contains { $0.productId == productId }
    }

    static func restoreSubscriptions() async throws -> Int {
        try await AppStore.sync()
        var restored = 0
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  isSubscription(productId: transaction.productID) else { continue }
            if await confirm(result, outTradeNo: nil) { restored += 1 }
        }
        return restored
    }

    /// 未验签的交易一律不送去入账——`.unverified` 意味着 StoreKit 自己都不认这份签名。
    @discardableResult
    static func confirm(_ result: VerificationResult<StoreKit.Transaction>, outTradeNo: String?) async -> Bool {
        guard case .verified(let tx) = result else { return false }
        return await confirm(tx, jws: result.jwsRepresentation, outTradeNo: outTradeNo)
    }

    /// 主动拉一次未完成交易并重放。`Transaction.unfinished` 里躺着的都是「钱已经付了、我们
    /// 还没入账」的交易：设置页的「恢复未完成的购买」与 App 启动各走一次。
    /// 返回这轮成功入账的笔数。
    @discardableResult
    static func replayUnfinished() async -> Int {
        var landed = 0
        for await result in StoreKit.Transaction.unfinished {
            if await confirm(result, outTradeNo: nil) { landed += 1 }
        }
        return landed
    }

    @MainActor private static var updatesTask: Task<Void, Never>?

    /// App 启动时挂上，整个进程生命周期都在听：StoreKit 会在这里补发进程外完成的交易
    /// （Ask to Buy 批准、在 App 外完成的购买、上次没 finish 的）。
    ///
    /// **只挂一次**，且**不要写成 `App` 结构体的属性初始化式**：SwiftUI 会反复重建 App 值，
    /// 每重建一次就多起一个监听，实测直接把主线程拖死在启动屏上（白屏，2026-09-13 走查现场）。
    @MainActor
    static func startObservingUpdates() {
        guard updatesTask == nil else { return }
        updatesTask = Task.detached {
            for await result in StoreKit.Transaction.updates {
                await confirm(result, outTradeNo: nil)
            }
        }
    }
}

/// 档位求交。**契约（`contract/products.json` 的 appstore 段）是档位来源，StoreKit 是价格来源**：
/// 只显示两边都有的档位，StoreKit 没返回的（商品还没审核通过、该地区没上架、id 打错）直接不显示——
/// 显示一个买不了的按钮比少一个档位糟得多，更不能因为取不到就崩。顺序跟契约走。
enum RechargeTiers {
    static func intersect(contract: [ContractProduct], storeProductIds: [String]) -> [ContractProduct] {
        let available = Set(storeProductIds)
        return contract.filter { available.contains($0.productId) }
    }
}
