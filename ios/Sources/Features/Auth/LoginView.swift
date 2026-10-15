import SwiftUI

/// Regional account methods remain shared with the login-method tests.
enum LoginMethod: Equatable, Sendable {
    case phone, email

    /// 该区域能用哪几种方式，按界面上的顺序。国际站没有短信通道，只剩邮箱。
    static func available(in region: AccountRegion) -> [LoginMethod] {
        region.allowsPhoneLogin ? [.phone, .email] : [.email]
    }

    /// 进门先看见哪一种。
    ///
    /// 国际区只有邮箱，没得选。大陆区保持原样：按包名定——短信通道只有阿里云的
    /// 大陆签名，**发不到境外号码**，非大陆包默认邮箱，免得海外用户一进门就对着
    /// 一个填不了的手机号框；大陆包默认手机号。
    static func defaultMethod(in region: AccountRegion, bundleID: String?) -> LoginMethod {
        guard region.allowsPhoneLogin else { return .email }
        return bundleID == "com.aiworkdeck.mobile.cn" ? .phone : .email
    }
}

/// Password sign-in uses the same account authority as desktop and website.
struct LoginView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var region: AccountRegion = .current
    @State private var method = LoginMethod.defaultMethod(in: .current, bundleID: Bundle.main.bundleIdentifier)
    @State private var identity = ""
    @State private var password = ""
    @State private var busy = false
    @State private var reviewMode = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: T.Sp.s4) {
                if ContractCapabilities.intlAccount {
                    Picker(tr("login.region.a11y"), selection: $region) {
                        ForEach(AccountRegion.allCases, id: \.self) { r in Text(tr(r.labelKey)).tag(r) }
                    }.pickerStyle(.segmented).disabled(busy)
                }
                Text(tr("login.title")).font(T.F.display()).foregroundStyle(T.L.fg)
                Text(tr("login.passwordHint")).font(T.F.micro()).foregroundStyle(T.L.fgMuted)
                if LoginMethod.available(in: region).count > 1 {
                    Picker(tr("login.title"), selection: $method) {
                        Text(tr("login.phone")).tag(LoginMethod.phone)
                        Text(tr("login.email")).tag(LoginMethod.email)
                    }.pickerStyle(.segmented).disabled(busy)
                }
                TextField(tr(method == .phone ? "login.phonePlaceholder" : "login.emailPlaceholder"), text: $identity)
                    .keyboardType(method == .phone ? .phonePad : .emailAddress)
                    .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .disabled(busy).accessibilityIdentifier("login.identity")
                Hairline()
                SecureField(tr(reviewMode ? "login.reviewCredential" : "login.passwordPlaceholder"), text: $password)
                    .textContentType(.password).disabled(busy).accessibilityIdentifier("login.password")
                Hairline()
                if let error { Text(error).font(T.F.micro()).foregroundStyle(T.S.failed) }
                Button { Task { await signIn() } } label: {
                    HStack { Text(tr(busy ? "login.working" : "login.title")); Spacer(); if busy { ProgressView() } }
                        .frame(minHeight: T.touchMin)
                }.disabled(busy || identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
                    .accessibilityIdentifier("login.submit")
                Button(tr(reviewMode ? "login.passwordMode" : "login.review")) { reviewMode.toggle(); password = ""; error = nil }.frame(minHeight: T.touchMin).disabled(busy).accessibilityIdentifier("login.review")
                Button(tr("login.register")) { openAccountFlow("register") }.frame(minHeight: T.touchMin).disabled(busy).accessibilityIdentifier("login.register")
                Button(tr("login.forgotPassword")) { openAccountFlow("reset") }.frame(minHeight: T.touchMin).disabled(busy).accessibilityIdentifier("login.reset")
                Text(tr("login.webHint")).font(T.F.micro()).foregroundStyle(T.L.fgMuted)
            }.padding(T.Sp.gutter)
        }.background(T.L.bg)
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: region) { _, value in
            model.switchRegion(to: value)
            method = LoginMethod.defaultMethod(in: value, bundleID: Bundle.main.bundleIdentifier)
            clearInputs()
        }
        .onChange(of: method) { _, _ in clearInputs() }
    }

    private func clearInputs() { identity = ""; password = ""; error = nil; reviewMode = false }

    private func openAccountFlow(_ flow: String) {
        password = ""; error = nil; reviewMode = false
        let host = region == .intl ? "https://workdeck.ai/en/account" : "https://aiworkdeck.com/zh/account"
        guard let url = URL(string: host + "?flow=" + flow) else { return }
        openURL(url) { accepted in if !accepted { error = tr("login.webError") } }
    }

    private func signIn() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let account = identity.trimmingCharacters(in: .whitespacesAndNewlines)
            let result: LoginResult
            if reviewMode {
                result = method == .phone
                    ? try await API.shared.verifyLoginCode(phone: account, code: password)
                    : try await API.shared.verifyMailLoginCode(email: account, code: password)
            } else {
                result = try await API.shared.accountLogin(account: account, password: password)
            }
            password = ""
            await model.didLogin(result)
        } catch { self.error = error.localizedDescription }
    }
}
