// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import StoreKit
import SwiftUI

/// 订阅页：价格是主角，一个主按钮，其余（恢复、管理、条款）都是页脚小链接。
/// 名称与权益说明直接用 App Store 商品的本地化 displayName / description，
/// 改权益只改 App Store Connect，不用发版。
struct SubscriptionView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var product: Product?
    @State private var closed = false
    @State private var loading = true
    @State private var busy = false
    @State private var hint = ""
    @State private var manage = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: T.Sp.s4) {
                    if loading {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, T.Sp.s16)
                    } else if let product {
                        Eyebrow(text: product.displayName).padding(.top, T.Sp.s6)
                        Text(tr("subscription.store.price", ["price": product.displayPrice]))
                            .font(T.F.display()).foregroundStyle(T.L.fg)
                            .monospacedDigit()
                        Text(product.description)
                            .font(T.F.body()).foregroundStyle(T.L.fgMuted)
                            .fixedSize(horizontal: false, vertical: true)
                        Button { Task { await buy(product) } } label: {
                            Group {
                                if busy { ProgressView().tint(.white) }
                                else { Text(tr("subscription.store.buy", ["price": product.displayPrice])) }
                            }
                            .font(T.F.body().weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 50)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(T.L.accent)
                        .disabled(busy)
                        .padding(.top, T.Sp.s4)
                        .accessibilityIdentifier("subscription.buy")
                    } else {
                        Text(tr(closed ? "subscription.store.closed" : "recharge.ios.storeUnavailable"))
                            .font(T.F.body()).foregroundStyle(T.L.fgMuted)
                            .padding(.top, T.Sp.s10)
                    }
                    if !hint.isEmpty {
                        Text(hint).font(T.F.small()).foregroundStyle(T.L.fg)
                            .accessibilityIdentifier("subscription.result")
                    }
                    Text(tr("subscription.store.renewal"))
                        .font(T.F.nano()).foregroundStyle(T.L.fgFaint)
                        .fixedSize(horizontal: false, vertical: true)
                    Hairline().padding(.top, T.Sp.s4)
                    HStack(spacing: T.Sp.s5) {
                        link(tr("subscription.store.restore")) { Task { await restore() } }
                            .accessibilityIdentifier("subscription.restore")
                        link(tr("subscription.store.manage")) { manage = true }
                    }
                    HStack(spacing: T.Sp.s5) {
                        Link(tr("subscription.store.terms"), destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                        Link(tr("privacy.policy"), destination: URL(string: "https://www.aiworkdeck.com/zh/legal/mobile-privacy")!)
                    }
                    .font(T.F.small()).foregroundStyle(T.L.fgMuted)
                }
                .padding(.horizontal, T.Sp.gutter)
                .padding(.bottom, T.Sp.s10)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(T.L.bg)
            .navigationTitle(tr("subscription.store.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button(tr("common.close")) { dismiss() } } }
            .manageSubscriptionsSheet(isPresented: $manage)
            .task {
                defer { loading = false }
                guard let capability = try? await API.shared.subscriptionCapability() else { return }
                // 服务端没开售：说「暂未开放」，不要甩锅给 App Store
                guard capability.available, IAP.isSubscription(productId: capability.productId) else { closed = true; return }
                product = try? await Product.products(for: ContractProducts.appstoreSubscriptions.map(\.productId))
                    .first(where: { $0.id == capability.productId && $0.type == .autoRenewable && $0.subscription?.subscriptionPeriod.value == 1 && $0.subscription?.subscriptionPeriod.unit == .month })
            }
        }
    }

    private func link(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(T.F.small()).foregroundStyle(T.L.accent)
            .frame(minHeight: T.touchMin)
            .disabled(busy)
    }

    @MainActor private func buy(_ product: Product) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let session = SessionStore.current
        do {
            let purchase = try await API.shared.prepareSubscription()
            guard session != nil, SessionStore.current == session, purchase.productId == product.id else {
                hint = tr("recharge.failed"); return
            }
            switch try await product.purchase(options: [.appAccountToken(purchase.appAccountToken)]) {
            case .success(let result):
                hint = await IAP.confirm(result, outTradeNo: nil) ? tr("common.ok") : tr("recharge.ios.pending")
            case .pending: hint = tr("recharge.ios.pending")
            case .userCancelled: break
            @unknown default: hint = tr("recharge.failed")
            }
        } catch let error as API.BillingError { hint = error.message }
        catch {
#if DEBUG
            if SubscriptionUITestSeed.isOn {
                let failure = error as NSError
                print("Subscription fixture purchase failed: \(failure.domain) / \(failure.code)")
            }
#endif
            hint = tr("recharge.failed")
        }
    }

    @MainActor private func restore() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            hint = try await IAP.restoreSubscriptions() > 0 ? tr("common.ok") : tr("recharge.ios.restoreNone")
        } catch let error as API.BillingError { hint = error.message }
        catch { hint = tr("recharge.failed") }
    }
}
