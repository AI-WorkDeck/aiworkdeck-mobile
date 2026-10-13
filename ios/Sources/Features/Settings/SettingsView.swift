import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var deleteError: String?
    var onClose: () -> Void

    @State private var saveToAlbum = Prefs.saveToAlbum
    @State private var albumError: String?
    @State private var usage: API.MediaUsage?
    @State private var balanceState: BalanceState = .unknown
    @State private var showRecharge = false
    @State private var showProjects = false
    @State private var showBackup = false

    /// 本端走内购（契约 capabilities.recharge = "iap"）。取这个值而不是写死 true：
    /// 契约改成别的通道时这一行会跟着变，界面不会偷偷留着一个错的入口。
    private static let canRecharge = ContractCapabilities.recharge == "iap"

    /// 还没读完时（`.unknown`）不渲染余额那一行，避免加载中闪一下无意义占位再消失
    /// （N6：未知态不渲染，不是先显示占位再消失）。失败态怎么渲染**不在这里判**，
    /// 交给 `API.balanceRowPlan`（唯一来源是 contract/schema/billing.schema.json 的 UI 映射，
    /// 与小程序 utils/money.ts 逐条对齐）——自从 iOS 有了充值入口，NOT_CONNECTED 与
    /// DISABLED / REVIEW_ACCOUNT 的呈现不再一样（dev-board#535）。
    private enum BalanceState {
        case unknown
        case ok(API.BillingBalance)
        case failed(API.BillingKind?)
    }

    /// 余额行 + 充值入口的渲染方案；`.unknown` 时两个都不渲染。
    /// 国际区计费未开通（dev-board#664）：行与入口一律不渲染，也不去拉余额。
    private var plan: API.BalanceRowPlan {
        guard AccountRegion.current.billingEnabled else {
            return API.BalanceRowPlan(showRow: false, showRecharge: false, textKey: nil)
        }
        switch balanceState {
        case .unknown:
            return API.BalanceRowPlan(showRow: false, showRecharge: false, textKey: nil)
        case .ok:
            return API.BalanceRowPlan(showRow: true, showRecharge: Self.canRecharge, textKey: nil)
        case .failed(let kind):
            return API.balanceRowPlan(kind: kind, canRecharge: Self.canRecharge)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    group(tr("settings.media")) {
                        Toggle(isOn: $saveToAlbum) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tr("settings.saveToAlbum"))
                                    .font(T.F.body())
                                    .foregroundStyle(T.L.fg)
                                // 把权衡摆在这儿，让每次选择都是知情的。
                                // 这不是吓唬人——尽调影像进相册，手机丢了或被查时
                                // 它就躺在那儿。
                                Text(tr("settings.saveToAlbum.hint"))
                                    .font(T.F.nano())
                                    .foregroundStyle(T.L.fgFaint)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .tint(T.L.accent)
                        .onChange(of: saveToAlbum) { _, v in
                            Prefs.saveToAlbum = v
                            if v { Task { await requestAlbumPermission() } }
                        }

                        if let albumError {
                            Text(albumError)
                                .font(T.F.nano())
                                .foregroundStyle(T.S.failed)
                                .padding(.top, T.Sp.s2)
                        }

                        infoRow(tr("settings.originals"), tr("settings.originals.hint"))
                    }

                    group(tr("settings.archiveTarget")) {
                        infoRow(tr("home.eyebrow"), model.project.name)
                        infoRow(tr("settings.relay"), usageCaption)
                        if let caption = persistentCaption {
                            infoRow(tr("settings.persistent"), caption)
                        }
                        Button(tr("settings.switchProject")) { showProjects = true }
                            .accessibilityIdentifier("settings.switchProject")
                            .font(T.F.small())
                            .foregroundStyle(T.L.accent)
                            .frame(minHeight: T.touchMin, alignment: .leading)
                    }

                    group(tr("backup.title")) {
                        if let consent = model.backupConsent {
                            Text(tr(consent.enabled ? "backup.enabled" : "backup.disabled"))
                        }
                        if let error = model.backupError { Text(error).foregroundStyle(T.S.failed) }
                        Button(tr("backup.title")) { showBackup = true }
                            .accessibilityIdentifier("settings.backup")
                            .frame(minHeight: T.touchMin)
                    }

                    group(tr("watch.title")) {
                        Text(tr("watch.phoneHint"))
                            .font(T.F.small()).foregroundStyle(T.L.fgMuted)
                        if let error = WatchPhoneBridge.shared.lastError {
                            Text(error).font(T.F.small()).foregroundStyle(T.S.failed)
                        }
                        Button(tr("watch.retry")) {
                            WatchPhoneBridge.shared.publishContext()
                            Task { await WatchPhoneBridge.shared.importPending() }
                        }
                        .frame(minHeight: T.touchMin)
                    }

                    group(tr("settings.account")) {
                        infoRow(tr("settings.signedIn"), model.account?.displayName ?? "—")
                        // 还没读完时整行不渲染，见 BalanceState 上的注释。
                        if let caption = balanceCaption {
                            infoRow(tr("balance.title"), caption)
                        }
                        if case .ok(let b) = balanceState, let sub = b.subscription, sub.active {
                            infoRow(tr("subscription.available"), credits(sub.availableCents))
                            infoRow(tr("subscription.weekly"), "\(credits(sub.weeklyUsedCents)) / \(credits(sub.weeklyLimitCents))")
                            infoRow(tr("subscription.monthly"), "\(credits(sub.monthlyUsedCents)) / \(credits(sub.monthlyLimitCents))")
                        }
                        // 充值入口与余额行分开算：NOT_CONNECTED 时行在、入口也要在
                        // （dev-board#535：触发 NOT_CONNECTED 的正是最该去充值把账户开出来的人）。
                        if plan.showRecharge {
                            Button(tr("recharge.entry")) { showRecharge = true }
                                .font(T.F.small())
                                .foregroundStyle(T.L.accent)
                                .frame(minHeight: T.touchMin, alignment: .leading)
                            if case .failed(.notConnected) = balanceState {
                                Text(tr("recharge.openHint"))
                                    .font(T.F.nano())
                                    .foregroundStyle(T.L.fgFaint)
                            }
                        }
                        // 区域登录后固定，这里只读；换区要退出登录后在登录页重选。
                        infoRow(tr("settings.region"), tr(AccountRegion.current.labelKey))
                        infoRow(tr("settings.server"), Backend.baseURL.host ?? "—")
                        Button(tr("common.signOut")) { model.signOut(); onClose() }
                            .font(T.F.small())
                            .foregroundStyle(T.S.failed)
                            .frame(minHeight: T.touchMin, alignment: .leading)

                        // 审核指南 5.1.1(v)：支持注册就必须在 App 内能删账号。
                        // 放在退出登录下面、字号更小，是因为它比退出重得多，
                        // 不该跟退出长得一样容易误点。
                        Button(tr("settings.deleteAccount")) { confirmDelete = true }
                            .font(T.F.micro())
                            .foregroundStyle(T.L.fgMuted)
                            .frame(minHeight: T.touchMin, alignment: .leading)
                    }

                    group(tr("settings.about")) {
                        infoRow(tr("settings.version"), Device.facts.appVersion)
                        infoRow(tr("settings.help"), "hi@aiworkdeck.com")
                    }
                }
                .padding(.horizontal, T.Sp.gutter)
                .padding(.bottom, T.Sp.s16)
            }
            .background(T.L.bg)
            // 进页面拉一次用量。失败静默——占位「—」比一条报错更符合这行信息的分量
            .task {
#if DEBUG
                // 截图模式不打网络请求：等超时只会截到一行「—」
                if Shot.isOn || WorkspaceUITestSeed.isOn {
                    usage = API.MediaUsage(usedBytes: Shot.usage.used, quotaBytes: Shot.usage.quota)
                    return
                }
#endif
                usage = try? await API.shared.mediaUsage()
            }
            // 读余额永不建号（C1）：这是一次纯读，未关联时服务端也不会替用户建号。
            // 按 kind 分支，不匹配 message 措辞（C2）；网络错误或解码失败一并落到
            // .unavailable。NOT_CONNECTED / DISABLED / REVIEW_ACCOUNT 归并成 .hidden——
            // 三者都不会自己恢复，整行不渲染（N2）；映射表见 API.decodeBillingBalance。
            .task { await loadBalance() }
            .navigationTitle(tr("home.settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(tr("common.close"), action: onClose).accessibilityIdentifier("settings.close")
                }
            }
            .sheet(isPresented: $showBackup) { BackupConsentView().environment(model) }
            .sheet(isPresented: $showProjects) {
                ProjectPickerView(onClose: { showProjects = false }).environment(model)
            }
            // 充值回来重拉一次余额：刚充的钱要在这一行上看得见，否则用户不知道到没到账
            .sheet(isPresented: $showRecharge, onDismiss: { Task { await loadBalance() } }) {
                RechargeView(onClose: { showRecharge = false })
            }
            // 不可逆，所以用 alert 而不是直接执行；文案要把「删什么、不删什么」
            // 都说全——只写「无法恢复」等于没说清代价。
            .alert(tr("settings.deleteAccount.title"), isPresented: $confirmDelete) {
                Button(tr("common.cancel"), role: .cancel) {}
                Button(tr("settings.deleteAccount.action"), role: .destructive) { Task { await runDelete() } }
            } message: {
                Text(tr("settings.deleteAccount.confirm"))
            }
            .alert(tr("settings.deleteAccount.failed"), isPresented: Binding(
                get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
                Button(tr("common.ok"), role: .cancel) { deleteError = nil }
            } message: {
                Text(deleteError ?? "")
            }
            .overlay {
                if deleting {
                    ZStack {
                        Color.black.opacity(0.25).ignoresSafeArea()
                        ProgressView(tr("settings.deleteAccount.deleting"))
                    }
                }
            }
        }
    }

    /// 读余额永不建号（C1）：这是一次纯读，未关联时服务端也不会替用户建号。
    /// 按 kind 分支，不匹配 message 措辞（C2）；网络错误或解码失败一并落到 `.failed(nil)`，
    /// 怎么渲染见 `plan`。
    private func loadBalance() async {
#if DEBUG
        // 截图模式不打网络请求。余额行留在 .unknown（整行不渲染）——
        // 上架截图上摆一个编出来的余额，等于对着审核和用户报一个假数。
        if Shot.isOn || WorkspaceUITestSeed.isOn { return }
#endif
        guard AccountRegion.current.billingEnabled else { return }
        if let result = try? await API.shared.billingBalance() {
            switch result {
            case .ok(let b): balanceState = .ok(b)
            case .failed(let kind): balanceState = .failed(kind)
            }
        } else {
            balanceState = .failed(nil)
        }
    }

    /// 注销成功后直接关掉设置页——账号没了，停在这一页没有意义，
    /// RootView 会因为 account 变 nil 自己回到登录页。
    private func runDelete() async {
        deleting = true
        do {
            try await model.deleteAccount()
            deleting = false
            onClose()
        } catch {
            deleting = false
            deleteError = error.localizedDescription
        }
    }

    @ViewBuilder
    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: T.Sp.s3) {
            Eyebrow(text: title)
                .padding(.top, T.Sp.s6)
                .padding(.bottom, T.Sp.s1)
            content()
            Hairline().padding(.top, T.Sp.s2)
        }
    }

    private func infoRow(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).font(T.F.small()).foregroundStyle(T.L.fg)
            Text(v)
                .font(T.F.nano())
                .foregroundStyle(T.L.fgFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 「已用 / 配额」。满了之后上传会被拒并提示去桌面端收件，这行让用户提前有数。
    private func credits(_ cents: Int64) -> String {
        tr("subscription.credits", ["amount": String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), Double(cents) / 100)])
    }

    private var persistentCaption: String? {
        guard let used = usage?.persistentUsedBytes else { return nil }
        let f = ByteCountFormatter()
        f.countStyle = .binary
        let usedText = f.string(fromByteCount: used)
        guard usage?.persistentQuotaAvailable != false, let quota = usage?.persistentQuotaBytes else {
            return tr("settings.quotaUnavailable", ["used": usedText])
        }
        return "\(usedText) / \(f.string(fromByteCount: quota))"
    }

    private var usageCaption: String {
        guard let usage else { return "—" }
        let f = ByteCountFormatter()
        f.countStyle = .binary
        return "\(f.string(fromByteCount: usage.usedBytes)) / \(f.string(fromByteCount: usage.quotaBytes))"
    }

    /// 统一账户余额展示。`nil` 表示这一行整个不渲染——`.unknown` 还没读完（N6：未知态不渲染，
    /// 不是先显示占位再消失），失败态按 `plan` 走（DISABLED / REVIEW_ACCOUNT 整行不渲染，
    /// 不给对这些终态无效的补救指引）。
    private var balanceCaption: String? {
        if case .ok(let balance) = balanceState {
            return tr("balance.amount", ["amount": Self.formatAmount(cents: balance.balanceCents, currency: balance.currency)])
        }
        let p = plan
        guard p.showRow, let key = p.textKey else { return nil }
        return tr(key)
    }

    /// 金额展示口径唯一来源：contract/schema/billing.schema.json 的展示口径说明段，
    /// fixtures/billing.json 的 balance.display 是期望输出，与 ContractFixturesTests 对拍。
    /// **不用 `NumberFormatter`**：它默认带千分位、小数点字符跟设备 locale 走——德语设备上
    /// 123456 分会被格式化成「¥1.234,56」，与安卓/小程序的「¥1234.56」对不上
    /// （dev-board#425 二轮复审 N7）。整数除法/取余手动拼字符串，不经过任何 locale。
    /// 去掉 `private` 是为了让测试能直接调这个函数验证展示口径，不是为了给外部调用方开放。
    static func formatAmount(cents: Int64, currency: String) -> String {
        let symbol = currency == "USD" ? "$" : "¥"
        let sign = cents < 0 ? "-" : ""
        let absCents = cents.magnitude
        let whole = absCents / 100
        let frac = absCents % 100
        let fracStr = frac < 10 ? "0\(frac)" : "\(frac)"
        return "\(symbol)\(sign)\(whole).\(fracStr)"
    }

    private func requestAlbumPermission() async {
        if await AlbumSaver.ensureAuthorized() {
            albumError = nil
        } else {
            albumError = tr("settings.album.denied")
        }
    }
}
