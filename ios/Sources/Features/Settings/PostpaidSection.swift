// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

struct PostpaidSection: View {
    let canRepay: Bool
    let repay: () -> Void
    @State private var accountSession = SessionStore.current
    @State private var accountBase = Backend.baseURL
    @State private var state: PostpaidState?
    @State private var busy = false
    @State private var error: String?
    @State private var confirm = false
    @State private var confirmResume = false
    private func amount(_ cents: Int64, _ currency: String) -> String {
        (Decimal(cents) / 100).formatted(.currency(code: currency))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: T.Sp.s2) {
            Text(tr("postpaid.title")).font(T.F.small())
            if let state {
                let b = state.billing
                Text(tr("postpaid.limit") + ": " + amount(b.creditLimitCents, b.cashCurrency))
                Text(tr("postpaid.available") + ": " + amount(b.availableCreditCents, b.cashCurrency))
                Text(tr("postpaid.debt") + ": " + amount(b.debtCents, b.cashCurrency))
                if let value = PersonalDates.display(b.remindAt) { Text(tr("postpaid.remind") + ": " + value) }
                if let value = PersonalDates.display(b.cleanupAt) { Text(tr("postpaid.cleanup") + ": " + value) }
                Text(tr("postpaid.storageRate", ["amount": amount(b.storagePrice.cashCentsPerGiBMonth, b.storagePrice.cashCurrency)]))
                if let egress = b.egressPrice {
                    Text(tr("postpaid.egressRate", ["amount": amount(egress.cashCentsPerGiB, egress.cashCurrency)]))
                }
                Text(tr("postpaid.notice"))
                if !canRepay { Text(tr("postpaid.channelUnavailable")) }
                if state.cloudAccess.cleanupState == "complete" { Text(tr("postpaid.cleared")) }
                else if !state.cloudAccess.canUse { Text(tr("postpaid.restricted")) }
                if canRepay && !b.accepted && b.acceptEnabled && b.egressPrice != nil {
                    Button(tr("postpaid.accept")) { confirm = true }.disabled(busy)
                }
                if b.accepted && (state.cloudAccess.frozen != true || b.debtCents == 0) {
                    Button(tr("postpaid.resume")) { confirmResume = true }.disabled(busy)
                }
                if canRepay && b.debtCents > 0 { Button(tr("postpaid.repay"), action: repay).disabled(busy) }
            }
            if busy { ProgressView() }
            if let error { Text(error).foregroundStyle(T.S.failed) }
            Button(tr("project.retry")) { Task { await load() } }.disabled(busy)
        }
        .task { await load() }
        .alert(tr("postpaid.accept"), isPresented: $confirm) {
            Button(tr("common.cancel"), role: .cancel) {}
            Button(tr("postpaid.accept")) { Task { await load(accept: true) } }
        } message: { Text(tr("postpaid.notice")) }
        .alert(tr("postpaid.resume"), isPresented: $confirmResume) {
            Button(tr("common.cancel"), role: .cancel) {}
            Button(tr("postpaid.resume")) { Task { await load(resume: true) } }
        } message: { Text(tr("postpaid.resumeNotice")) }
    }
    @MainActor private func load(accept: Bool = false, resume: Bool = false) async {
        guard !busy, accountSession == SessionStore.current, accountBase == Backend.baseURL else { return }
        busy = true; error = nil
        do {
            if resume { await CloudEpoch.shared.invalidate(); try await UploadQueue.shared.pauseCloudUploads() }
            guard accountSession == SessionStore.current, accountBase == Backend.baseURL else { throw APIError(message: tr("files.error.closed")) }
            state = try await API.shared.cloudBillingState(policyVersion: (accept || (resume && state?.cloudAccess.frozen == true)) ? state?.billing.policyVersion : nil, resume: resume)
            if accept || resume {
                if let accountSession { try await CloudEpoch.shared.reconnect(base: accountBase, token: accountSession) }
            }
        }
        catch { self.error = tr("balance.unavailable") }
        busy = false
    }
}
