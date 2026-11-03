// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import StoreKit
import SwiftUI

struct SubscriptionView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var product: Product?
    @State private var loading = true
    @State private var busy = false
    @State private var hint = ""
    @State private var manage = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if loading { ProgressView() }
                    else if let product {
                        Text(product.displayName).font(.headline)
                        Text(product.description)
                        Button(tr("subscription.store.buy", ["price": product.displayPrice])) {
                            Task { await buy(product) }
                        }.disabled(busy).accessibilityIdentifier("subscription.buy")
                    } else { Text(tr("recharge.ios.storeUnavailable")) }
                    Text(tr("subscription.store.renewal")).font(.footnote)
                    if !hint.isEmpty { Text(hint).font(.footnote) }
                }
                Section {
                    Button(tr("subscription.store.restore")) { Task { await restore() } }.disabled(busy)
                    Button(tr("subscription.store.manage")) { manage = true }.disabled(busy)
                    Link(tr("subscription.store.terms"), destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                    Link(tr("privacy.policy"), destination: URL(string: "https://www.aiworkdeck.com/zh/legal/mobile-privacy")!)
                }
            }
            .navigationTitle(tr("subscription.store.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button(tr("common.close")) { dismiss() } } }
            .manageSubscriptionsSheet(isPresented: $manage)
            .task {
                defer { loading = false }
                guard let capability = try? await API.shared.subscriptionCapability(), capability.available,
                      IAP.isSubscription(productId: capability.productId) else { return }
                product = try? await Product.products(for: ContractProducts.appstoreSubscriptions.map(\.productId))
                    .first(where: { $0.id == capability.productId && $0.type == .autoRenewable && $0.subscription?.subscriptionPeriod.value == 1 && $0.subscription?.subscriptionPeriod.unit == .month })
            }
        }
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
        catch { hint = tr("recharge.failed") }
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
