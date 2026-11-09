// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// 设置页里的一行：名称 + 一个词的状态，点进去才是授信、费率与条款。
/// 大多数人从没开通过后付费，不该在设置首屏读一整段扣费条款。
struct PostpaidSection: View {
    let canRepay: Bool
    let repay: () -> Void
    @State private var model = PostpaidModel()
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: T.Sp.s3) {
                Text(tr("postpaid.title")).font(T.F.small()).foregroundStyle(T.L.fg)
                Spacer(minLength: T.Sp.s3)
                if let status { Text(status).font(T.F.small()).foregroundStyle(statusColor) }
                Image(systemName: "chevron.forward").font(.system(size: 12, weight: .semibold)).foregroundStyle(T.L.fgFaint)
            }
            .frame(minHeight: T.touchMin)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.postpaid")
        .task { await model.load() }
        .sheet(isPresented: $open, onDismiss: { Task { await model.load() } }) {
            PostpaidView(model: model, canRepay: canRepay, repay: { open = false; repay() })
        }
    }

    private var status: String? {
        if model.error != nil { return "—" }
        guard let state = model.state else { return nil }
        let b = state.billing
        if b.debtCents > 0 { return PostpaidModel.amount(b.debtCents, b.cashCurrency) }
        guard b.accepted else { return tr("postpaid.status.off") }
        return state.cloudAccess.canUse ? tr("postpaid.status.on") : tr("postpaid.status.restricted")
    }

    private var statusColor: Color {
        guard let b = model.state?.billing else { return T.L.fgMuted }
        return b.debtCents > 0 || (b.accepted && model.state?.cloudAccess.canUse == false) ? T.S.failed : T.L.fgMuted
    }
}

@MainActor @Observable
final class PostpaidModel {
    var state: PostpaidState?
    var busy = false
    var error: String?
    private let accountSession = SessionStore.current
    private let accountBase = Backend.baseURL

    static func amount(_ cents: Int64, _ currency: String) -> String {
        (Decimal(cents) / 100).formatted(.currency(code: currency))
    }

    func load(accept: Bool = false, resume: Bool = false) async {
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

/// 后付费详情：数字一行一项（名称左、值右），条款放最后当脚注，动作按钮只在能做时出现。
private struct PostpaidView: View {
    @Environment(\.dismiss) private var dismiss
    let model: PostpaidModel
    let canRepay: Bool
    let repay: () -> Void
    @State private var confirm = false
    @State private var confirmResume = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: T.Sp.s3) {
                    if let state = model.state {
                        let b = state.billing
                        let money = { (c: Int64) in PostpaidModel.amount(c, b.cashCurrency) }
                        if state.cloudAccess.cleanupState == "complete" { notice(tr("postpaid.cleared"), T.S.failed) }
                        else if b.accepted && !state.cloudAccess.canUse { notice(tr("postpaid.restricted"), T.S.failed) }

                        Spacer().frame(height: T.Sp.s2)
                        row(tr("postpaid.limit"),money(b.creditLimitCents))
                        row(tr("postpaid.available"), money(b.availableCreditCents))
                        row(tr("postpaid.debt"), money(b.debtCents), alert: b.debtCents > 0)
                        if let value = PersonalDates.display(b.remindAt) { row(tr("postpaid.remind"), value) }
                        if let value = PersonalDates.display(b.cleanupAt) { row(tr("postpaid.cleanup"), value) }
                        Hairline().padding(.vertical, T.Sp.s2)
                        Text(tr("postpaid.storageRate", ["amount": PostpaidModel.amount(b.storagePrice.cashCentsPerGiBMonth, b.storagePrice.cashCurrency)]))
                            .font(T.F.small()).foregroundStyle(T.L.fg)
                        if let egress = b.egressPrice {
                            Text(tr("postpaid.egressRate", ["amount": PostpaidModel.amount(egress.cashCentsPerGiB, egress.cashCurrency)]))
                                .font(T.F.small()).foregroundStyle(T.L.fg)
                        }
                        Text(tr("postpaid.notice"))
                            .font(T.F.nano()).foregroundStyle(T.L.fgFaint)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, T.Sp.s2)
                        if !canRepay {
                            Text(tr("postpaid.channelUnavailable")).font(T.F.nano()).foregroundStyle(T.L.fgFaint)
                        }

                        VStack(spacing: T.Sp.s3) {
                            if canRepay && b.debtCents > 0 { primary(tr("postpaid.repay"), action: repay) }
                            if canRepay && !b.accepted && b.acceptEnabled && b.egressPrice != nil {
                                primary(tr("postpaid.accept")) { confirm = true }
                            }
                            if b.accepted && (state.cloudAccess.frozen != true || b.debtCents == 0) {
                                Button(tr("postpaid.resume")) { confirmResume = true }
                                    .font(T.F.small()).foregroundStyle(T.L.accent)
                                    .frame(minHeight: T.touchMin)
                            }
                        }
                        .disabled(model.busy)
                        .padding(.top, T.Sp.s4)
                    } else if model.busy {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, T.Sp.s10)
                    }
                    if let error = model.error {
                        notice(error, T.S.failed)
                        Button(tr("project.retry")) { Task { await model.load() } }
                            .font(T.F.small()).foregroundStyle(T.L.accent)
                            .frame(minHeight: T.touchMin)
                    }
                }
                .padding(.horizontal, T.Sp.gutter)
                .padding(.bottom, T.Sp.s10)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(T.L.bg)
            .navigationTitle(tr("postpaid.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button(tr("common.close")) { dismiss() } } }
            .alert(tr("postpaid.accept"), isPresented: $confirm) {
                Button(tr("common.cancel"), role: .cancel) {}
                Button(tr("postpaid.accept")) { Task { await model.load(accept: true) } }
            } message: { Text(tr("postpaid.notice")) }
            .alert(tr("postpaid.resume"), isPresented: $confirmResume) {
                Button(tr("common.cancel"), role: .cancel) {}
                Button(tr("postpaid.resume")) { Task { await model.load(resume: true) } }
            } message: { Text(tr("postpaid.resumeNotice")) }
        }
    }

    private func row(_ k: String, _ v: String, alert: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).font(T.F.small()).foregroundStyle(T.L.fg)
            Spacer(minLength: T.Sp.s3)
            Text(v).font(T.F.small()).monospacedDigit().foregroundStyle(alert ? T.S.failed : T.L.fgMuted)
        }
        .frame(minHeight: 32)
    }

    private func notice(_ text: String, _ color: Color) -> some View {
        Text(text).font(T.F.small()).foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, T.Sp.s4)
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(T.F.body().weight(.semibold)).frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.borderedProminent)
        .tint(T.L.accent)
    }
}
