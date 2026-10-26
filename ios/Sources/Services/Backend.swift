import Foundation
import Security

/// 账号区域（dev-board#837）。大陆站与国际站是**两套账号体系**，同一个人在两边是两个号，
/// 所以区域跟着账号走，不跟着设备语言或系统地区走——只能由用户在登录页自己选。
///
/// 区域只在未登录的登录页切换；登录后固定，换区 = 退出登录后在登录页重选。
/// 存 UserDefaults 就够：它是偏好，不是凭据。
enum AccountRegion: String, CaseIterable, Sendable {
    /// 大陆站：手机号验证码（阿里云大陆短信）+ 邮箱验证码，已开通计费。
    case cn
    /// 国际站：没有短信通道（Twilio 未开、阿里云国际短信未开通），只走邮箱验证码；
    /// 计费尚未开通（dev-board#664）。
    case intl

    static let defaultsKey = "accountRegion"

    /// 缺省区域。**存量已登录用户没有这个键，必须落到大陆站**——他们的会话是大陆站发的，
    /// 缺省成别的区域等于升级后所有老用户的请求打到一个不认这个会话的主机上。
    static let fallback: AccountRegion = .cn

    var baseURL: URL {
        switch self {
        case .cn:   URL(string: "https://addin.aiworkdeck.com")!
        case .intl: URL(string: "https://addin.workdeck.ai")!
        }
    }

    /// 界面显示名的契约键。
    var labelKey: String { "login.region.\(rawValue)" }

    /// 手机号验证码登录只在大陆站可用；国际站那边 `sms-login/send-code` 会因为网关未启用而失败。
    var allowsPhoneLogin: Bool { self == .cn }

    /// 余额与充值入口。国际站计费未开通（dev-board#664），那边的余额行与入口整个不渲染。
    var billingEnabled: Bool { self == .cn }

    /// 存的值读不懂（空、旧版本写的、被手改过）一律按缺省处理，不崩、不猜。
    static func resolve(_ stored: String?) -> AccountRegion {
        stored.flatMap(AccountRegion.init(rawValue:)) ?? fallback
    }

    static func load(from defaults: UserDefaults) -> AccountRegion {
        resolve(defaults.string(forKey: defaultsKey))
    }

    static func save(_ region: AccountRegion, to defaults: UserDefaults) {
        defaults.set(region.rawValue, forKey: defaultsKey)
        if defaults == .standard {
            L10n.apply(region: region)
        }
    }

    static var current: AccountRegion {
        get { load(from: .standard) }
        set { save(newValue, to: .standard) }
    }
}

extension AccountRegion {
    /// 请求头 `X-App-Language`：区域默认语言代码（大陆版 zh-CN，海外版 en-US）。
    var appLanguage: String { self == .intl ? "en-US" : "zh-CN" }
}

/// 语言默认跟账号区域走（大陆版 zh-Hans，海外版 en），当用户主动选了语言偏好时以偏好为准。
extension L10n {
    static func locale(for region: AccountRegion) -> String {
        region == .intl ? "en" : "zh-Hans"
    }

    /// 启动时或登录页切区域时调用：若用户未指定语言偏好（system），则跟随区域默认语言。
    static func apply(region: AccountRegion, defaults: UserDefaults = .standard) {
        let pref = loadPreference(from: defaults)
        if preference != pref { preference = pref }
        let target = pref == systemPreference ? locale(for: region) : normalize(pref, fallback: locale(for: region))
        if locale != target { locale = target }
    }

    static func selectLanguage(_ pref: String, region: AccountRegion = .current, defaults: UserDefaults = .standard) {
        setPreference(pref, regionFallback: locale(for: region), defaults: defaults)
    }
}

/// 后端地址。整个 App 只在这里指向服务器——
/// 所以绝不能写死在调用点上。
enum Backend {
    /// 当前账号区域的主机。**每次请求现读**，不缓存：登录页切区域后下一次请求就该打到新主机上。
    static var baseURL: URL { AccountRegion.current.baseURL }
}

// MARK: - 会话存储

/// 会话令牌存 Keychain，不存 UserDefaults——那是凭据，不是偏好。
/// UserDefaults 明文躺在沙盒里，设备被解锁取证时一览无余。
enum SessionStore {
    private static let service = "com.aiworkdeck.mobile.session"
    private static let account = "sessionId"

    static var current: String? {
        get { read() }
        set {
            if let newValue { write(newValue) } else { clear() }
        }
    }

    private static func read() -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ value: String) {
        clear()
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            // 只在本机解锁后可读，且不同步到 iCloud 钥匙串——
            // 尽调设备的会话不该跟着 Apple ID 漂到别的设备上。
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(q as CFDictionary, nil)
    }

    private static func clear() {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}

// MARK: - 客户端

struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// 后端返回的统一信封：{ code, message, data }。code 0 才是成功。
private struct Envelope<T: Decodable>: Decodable {
    let code: Int
    let message: String?
    let data: T?
}

private struct Empty: Decodable {}

/// 两条登录路径共用一个结果形状。手机号那条回 `isNewUser`（号码没见过就建号），
/// 邮箱那条回 `mustBindPhone` 而没有 `isNewUser`——都做成可选，别为差一个字段拆两个类型。
struct LoginResult: Decodable {
    let sessionId: String
    let isNewUser: Bool?
    let mustBindPhone: Bool?
    let user: AccountUser
}

/// A cloud identity with explicit storage locations; legacy device/key snapshots remain valid.
struct ProjectLocation: Codable, Hashable, Sendable {
    let kind: String
    let deviceId: String
    let deviceName: String?
    let key: String
    let online: Bool?
    var archiveOnly: Bool? = nil
    var alias: String { deviceId + ":" + key }
}

struct RelayProject: Codable, Identifiable, Hashable, Sendable {
    let deviceId: String
    let deviceName: String?
    let key: String
    let name: String
    let projectUid: String?
    let locations: [ProjectLocation]?

    init(deviceId: String, deviceName: String?, key: String, name: String,
         projectUid: String? = nil, locations: [ProjectLocation]? = nil) {
        self.deviceId = deviceId; self.deviceName = deviceName; self.key = key; self.name = name
        self.projectUid = projectUid; self.locations = locations
    }

    enum CodingKeys: String, CodingKey { case deviceId, deviceName, key, name, projectUid, locations }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        projectUid = try c.decodeIfPresent(String.self, forKey: .projectUid)
        locations = try c.decodeIfPresent([ProjectLocation].self, forKey: .locations)
        // Persisted snapshots retain the original upload route, including after a failed attempt.
        if let device = try c.decodeIfPresent(String.self, forKey: .deviceId),
           let localKey = try c.decodeIfPresent(String.self, forKey: .key) {
            deviceId = device; key = localKey
            deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName)
        } else if let location = locations?.first(where: { $0.kind == "cloud" && $0.archiveOnly != true })
                    ?? locations?.first(where: { $0.kind == "desktop" && $0.online == true })
                    ?? locations?.first(where: { $0.kind == "desktop" }) ?? locations?.first {
            deviceId = location.deviceId; key = location.key; deviceName = location.deviceName
        } else {
            throw DecodingError.dataCorruptedError(forKey: .locations, in: c, debugDescription: "Project has no location")
        }
    }

    var id: String { projectUid ?? legacyID }
    var legacyID: String { deviceId + ":" + key }
    var isCloud: Bool { deviceId == "cloud" }
    var aliases: Set<String> { Set((locations ?? []).map(\.alias) + [legacyID]) }
    func matches(_ other: RelayProject) -> Bool {
        if let uid = projectUid, let otherUid = other.projectUid { return uid == otherUid }
        return !aliases.isDisjoint(with: other.aliases)
    }
    var identityCaption: String {
        if let projectUid { return tr("project.unifiedIdentity", ["id": projectUid]) }
        return tr("project.identity", ["key": key, "device": deviceId])
    }
}

struct CodeOnly: Decodable {
    let code: Int
    let message: String?
}

struct AccountUser: Decodable {
    let id: Int
    let username: String
    let displayName: String
    let avatarUrl: String
    let role: String
}

actor API {
    static let shared = API()

    /// 所有发往后端的请求都从这里起：当前区域的主机由调用方拼好传进来，这里补会话头与
    /// 语言头——后端据 `X-App-Language` 选报错语言（海外版 en-US，大陆版 zh-CN）。
    static func request(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        if let sid = SessionStore.current { req.setValue(sid, forHTTPHeaderField: "X-Session-Id") }
        req.setValue(L10n.wireCode, forHTTPHeaderField: "X-App-Language")
        return req
    }

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.waitsForConnectivity = true
        return URLSession(configuration: c)
    }()

    // MARK: 登录

    func accountLogin(account: String, password: String) async throws -> LoginResult {
        let r = try await post("/api/auth/account-login", body: ["account": account, "password": password], as: LoginResult.self)
        guard let r, !r.sessionId.isEmpty, r.user.id > 0 else { throw APIError(message: tr("error.loginNoData")) }
        SessionStore.current = r.sessionId
        return r
    }

    func sendLoginCode(phone: String) async throws {
        _ = try await post("/api/auth/sms-login/send-code",
                           body: ["phone": phone], as: Empty.self)
    }

    func verifyLoginCode(phone: String, code: String) async throws -> LoginResult {
        let r = try await post("/api/auth/sms-login/verify",
                               body: ["phone": phone, "code": code], as: LoginResult.self)
        guard let r else { throw APIError(message: tr("error.loginNoData")) }
        SessionStore.current = r.sessionId
        return r
    }

    /// 邮箱验证码登录发码。**只对已注册且已验证邮箱的账号发信**——后端对未注册地址
    /// 同样返回成功（不发信），免得这个匿名端点变成账号枚举器。所以「点了没收到」
    /// 既可能是没注册，也可能是投递慢，界面上不能替后端断言是哪一种。
    func sendMailLoginCode(email: String) async throws {
        _ = try await post("/api/auth/mail-login/send-code",
                           body: ["email": email], as: Empty.self)
    }

    func verifyMailLoginCode(email: String, code: String) async throws -> LoginResult {
        let r = try await post("/api/auth/mail-login/verify",
                               body: ["email": email, "code": code], as: LoginResult.self)
        guard let r else { throw APIError(message: tr("error.loginNoData")) }
        SessionStore.current = r.sessionId
        return r
    }

    /// 注销账号：删掉云端这个账号及其全部数据。
    ///
    /// App Store 审核指南 5.1.1(v)：支持注册的 App 必须在 App 内提供删除账号。
    /// **只删云端**——手机本地的原图不动。这是取证工具，现场不可复现，替用户
    /// 把本地影像一并销毁不是清理是毁证；界面上会写明这一点。
    func deleteAccount() async throws {
        _ = try await post("/api/auth/account/delete", body: [:], as: Empty.self)
        SessionStore.current = nil
    }

    /// 清会话只碰 Keychain，不需要进 actor 排队——登出必须是立刻生效的同步操作，
    /// 排在别的网络请求后面等于「点了登出还在登录状态」。
    nonisolated func logout() {
        SessionStore.current = nil
    }

    // MARK: 项目与上传

    /// 账号级统一项目目录，裸数组；包含持久项目身份与实际存储位置。
    /// 桌面离线时目录仍可见，在线状态由 locations.online 表达。
    func myProjects() async throws -> [RelayProject] {
        try await getRaw("/api/mobile/catalog", as: [RelayProject].self)
    }

    /// 上传一件现场影像到中转区（POST /api/mobile/media，单步 multipart）。
    /// 幂等键是 clientMediaId：弱网重传、进程被杀重启都不会在中转区产生重复件，
    /// 所以这里不需要「先建记录再传字节」的两段式。
    func upload(item: CaptureItem, project: RelayProject, fileName: String,
                progress: @Sendable @escaping (Double) -> Void) async throws {
        let baseURL = Backend.baseURL
        let sessionID = SessionStore.current
        if let binding = item.watchAccountBinding,
           binding != WatchAccountScope.binding(session: sessionID, baseURL: baseURL) {
            throw APIError(message: tr("watch.accountChanged"))
        }
        var req = Self.request(baseURL.appendingPathComponent("/api/mobile/media"))
        req.setValue(sessionID, forHTTPHeaderField: "X-Session-Id")
        req.httpMethod = "POST"
        let boundary = "awd-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let iso = ISO8601DateFormatter()
        // 三分支写死：录音落成 "video" 会被桌面端当录像归档，静默错档比报错更糟。
        let mediaType = switch item.kind {
        case .photo: "image"
        case .video: "video"
        case .audio: "audio"
        }
        let fields: [(String, String)] = [
            ("deviceId", project.deviceId),
            ("projectKey", project.key),
            ("clientMediaId", item.manifest.clientMediaId.uuidString.lowercased()),
            ("fileName", fileName),
            ("mediaType", mediaType),
            ("capturedAt", iso.string(from: item.capturedAt)),
        ]

        // 用 fromFile 而不是把整份读进内存：现场录像几百 MB，读进内存会被系统杀掉。
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("up-\(UUID().uuidString)")
        try makeMultipartFile(at: tmp, boundary: boundary, fields: fields,
                              source: item.localURL, uploadName: fileName)
        defer { try? FileManager.default.removeItem(at: tmp) }

        progress(0.05)
        let (data, resp) = try await session.upload(for: req, fromFile: tmp)
        progress(1)

        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let sc = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw APIError(message: tr("error.uploadFailed", ["code": String(sc)]))
        }
        // 后端这条返回 {code,...}；code 非 0 也算失败
        if let env = try? JSONDecoder().decode(CodeOnly.self, from: data), env.code != 0 {
            throw APIError(message: env.message ?? tr("error.uploadRejected"))
        }
    }

    struct MediaStatus: Decodable, Sendable {
        var projectUid: String? = nil
        var fileUid: String? = nil
        var fileId: Int64? = nil
        let clientMediaId: String
        let delivered: Bool
        let waitingSeconds: Int64
        /// 中转区到期时刻（ISO 本地时间字符串，仅未投递件有）。到期未取回即清理。
        let expiresAt: String?
    }

    struct MediaUsage: Decodable, Sendable {
        let usedBytes: Int64
        let quotaBytes: Int64
        var persistentUsedBytes: Int64? = nil
        var persistentQuotaBytes: Int64? = nil
        var persistentQuotaAvailable: Bool? = nil
    }

    /// 云端中转区用量（GET /api/mobile/media/usage）。裸对象，无信封。
    func mediaUsage() async throws -> MediaUsage {
        try await getRaw("/api/mobile/media/usage", as: MediaUsage.self)
    }

    /// 影像投递状态：delivered = 桌面端已确认落盘（中转区已删）。裸数组。
    func mediaStatus(clientMediaIds: [String]) async throws -> [MediaStatus] {
        guard !clientMediaIds.isEmpty else { return [] }
        var comps = URLComponents(url: Backend.baseURL.appendingPathComponent("/api/mobile/media/status"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "clientMediaIds", value: clientMediaIds.joined(separator: ","))]
        let req = Self.request(comps.url!)
        let (data, resp) = try await send(req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError(message: tr("error.server", ["code": String((resp as? HTTPURLResponse)?.statusCode ?? -1)]))
        }
        do { return try JSONDecoder().decode([MediaStatus].self, from: data) }
        catch { throw APIError(message: tr("error.badResponse")) }
    }

    // MARK: 账单

    /// 统一账户余额（dev-board#425，GET /api/mobile/billing/balance）。整数分，币种由部署站点决定。
    /// plan 是计费档位（`paid`/`free`），不是套餐名——不要把它直接渲染给用户。
    struct SubscriptionBalance: Decodable, Sendable {
        let active: Bool
        let availableCents: Int64
        let monthlyLimitCents: Int64
        let monthlyUsedCents: Int64
        let weeklyLimitCents: Int64
        let weeklyUsedCents: Int64
    }

    struct BillingBalance: Decodable, Sendable {
        let balanceCents: Int64
        let currency: String
        let plan: String?
        var subscription: SubscriptionBalance? = nil
    }

    /// 失败信封携带的机器可读判别位（dev-board#425 契约 `Envelope.kind`）。
    /// 一律按它分支，**禁止匹配 message 措辞**——message 经服务端 LangText 在英文部署下
    /// 会整条变成英文，硬编码中文串必然落空；code 也永远是 1，判 code 分不出这几种情况。
    enum BillingKind: String, Decodable, Sendable, CaseIterable {
        case disabled = "DISABLED"
        case unavailable = "UNAVAILABLE"
        case notConnected = "NOT_CONNECTED"
        case notFound = "NOT_FOUND"
        case rejected = "REJECTED"
        case reviewAccount = "REVIEW_ACCOUNT"
        case alreadyPaid = "ALREADY_PAID"
        case idempotencyConflict = "IDEMPOTENCY_CONFLICT"
    }

    /// 失败信封 {code, message, kind, outTradeNo}。kind/outTradeNo 缺席时 JSONDecoder
    /// 对可选字段的默认行为就是解成 nil（服务端 putIfPresent 对缺席键本就不出现在响应里）。
    private struct BillingEnvelope: Decodable {
        let code: Int
        let message: String?
        let kind: BillingKind?
        let outTradeNo: String?
    }

    /// 读余额的两种结果。**怎么渲染由 `balanceRowPlan` 决定，不在这里收窄**——
    /// 自从 iOS 有了充值入口（dev-board#426），NOT_CONNECTED 与 DISABLED / REVIEW_ACCOUNT
    /// 的呈现不再一样（前者要显示余额行 + 充值入口，见 dev-board#535），把 kind 提前拍平成
    /// 「显 / 不显」就再也分不出来了。kind 缺席（网络错误 / 解码失败 / 非 billing 专有的失败）
    /// 一律是 `.failed(nil)`，按瞬时故障走 balance.unavailable——绝不能显示成「没有账户」或「余额 0」。
    enum BillingBalanceResult: Sendable {
        case ok(BillingBalance)
        case failed(BillingKind?)
    }

    /// 余额那一行与充值入口的渲染方案。
    struct BalanceRowPlan: Equatable, Sendable {
        let showRow: Bool
        let showRecharge: Bool
        /// 余额行的文案键；nil 表示这一行不渲染文案（整行不渲染，或成功路径直接显示金额）
        let textKey: String?
    }

    /// 余额拉失败时该怎么渲染，唯一来源是 contract/schema/billing.schema.json 的 UI 映射
    /// （一律按 kind 分支，**禁止匹配 message 措辞**）。与小程序 utils/money.ts 的
    /// `balanceRowForError` 同一张表，逐条对齐：
    ///  - DISABLED / REVIEW_ACCOUNT：整行不渲染、入口一并收起（本部署没开通 / 审核演示账号，
    ///    审核员看到的必须是干净的设置页）；
    ///  - NOT_CONNECTED：有真实支付通道的端（iOS 是 iap）渲染余额行 + balance.notConnected +
    ///    **充值入口照常可见**——触发它的正是还没有统一账户、最该去充值把账户开出来的那批人，
    ///    连入口一起藏掉就等于界面上找不到充值口（dev-board#535）；没有充值通道的端整行不渲染；
    ///  - 其余（含 kind 缺席）：显示 balance.unavailable，入口保持可见——读不到余额不代表下不了单。
    static func balanceRowPlan(kind: BillingKind?, canRecharge: Bool) -> BalanceRowPlan {
        switch kind {
        case .disabled, .reviewAccount:
            return BalanceRowPlan(showRow: false, showRecharge: false, textKey: nil)
        case .notConnected:
            return canRecharge
                ? BalanceRowPlan(showRow: true, showRecharge: true, textKey: "balance.notConnected")
                : BalanceRowPlan(showRow: false, showRecharge: false, textKey: nil)
        default:
            return BalanceRowPlan(showRow: true, showRecharge: canRecharge, textKey: "balance.unavailable")
        }
    }

    /// 判读裸响应或失败信封——这是 `billingBalance()` 真正在用的判读逻辑，抽成静态函数
    /// 是为了让契约夹具测试能直接驱动它（二轮复审 N4：以前测试文件里另外声明了一份
    /// `struct Envelope` 自己解码，这段判读代码一行测试都没有覆盖过，改坏了也不会有测试变红；
    /// 见 `ContractFixturesTests.testBillingBalanceKindMappingFixtures` 与
    /// `testBillingBalanceDecodeFixtures`）。
    static func decodeBillingBalance(status: Int, data: Data) -> BillingBalanceResult {
        guard (200...299).contains(status) else { return .failed(nil) }
        // 先探 code 字段：出现即失败信封，没有才当裸对象解。反过来先按 BillingBalance
        // 硬解会在信封响应上报「缺字段」解码错误，而不是干净地落到失败分支。
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], obj["code"] != nil {
            return .failed((try? JSONDecoder().decode(BillingEnvelope.self, from: data))?.kind)
        }
        guard let balance = try? JSONDecoder().decode(BillingBalance.self, from: data) else {
            return .failed(nil)
        }
        return .ok(balance)
    }

    /// 裸对象或失败信封共用同一个 200；判读逻辑在 `decodeBillingBalance`（可测）。
    func billingBalance() async throws -> BillingBalanceResult {
        let req = Self.request(Backend.baseURL.appendingPathComponent("/api/mobile/billing/balance"))
        let (data, resp) = try await send(req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        return Self.decodeBillingBalance(status: status, data: data)
    }

    // MARK: 充值（iOS 内购，dev-board#426）

    /// 业务失败信封（code 1 + kind）。`kind` 是**机器可读判别位**，调用方一律按它分支；
    /// `message` 已由服务端 LangText 出成可读话术，原样展示即可，绝不按措辞匹配。
    struct BillingError: LocalizedError, Sendable {
        let message: String
        let kind: BillingKind?
        /// 只有 ALREADY_PAID / IDEMPOTENCY_CONFLICT 会带：App 被杀、本地没存下单号时靠它恢复。
        let outTradeNo: String?
        var errorDescription: String? { message }
    }

    /// 充值单。契约见 contract/schema/billing.schema.json 的 recharge 段：
    /// **不适用的键在响应里不出现，解码后一律是 nil，不是空串**。
    /// present=native 是 iOS 内购（服务端只建单，钱走 StoreKit），此时只有 appAccountToken 有值。
    struct RechargeOrder: Equatable, Sendable {
        let present: String
        let outTradeNo: String
        let amountCents: Int
        let codeUrl: String?
        let qrCode: String?
        let redirectUrl: String?
        let signData: String?
        let paySig: String?
        let signature: String?
        /// present=native 必有：UUID，官网建单时落进 orders.providerRef。端上原样传给
        /// `Product.PurchaseOption.appAccountToken`——StoreKit 2 只有这一个字段能可靠原样
        /// 回到 JWS 里，这笔单与那笔交易全靠它挂钩。
        let appAccountToken: String?
    }

    /// 服务端裸响应原文。可选键缺席时 JSONDecoder 解成 nil，正是契约要的。
    private struct RawRechargeOrder: Decodable {
        let present: String
        let outTradeNo: String
        let amountCents: Int
        let codeUrl: String?
        let qrCode: String?
        let redirectUrl: String?
        let signData: String?
        let paySig: String?
        let signature: String?
        let appAccountToken: String?
    }

    struct RechargeStatus: Decodable, Equatable, Sendable {
        let status: String
        let paid: Bool
        let amountCents: Int
    }

    /// 空串也当缺席（与小程序 `decodeRechargeOrder` 的 `optional()` 同口径）：
    /// 契约钉的是「缺席 → null，不是空串」，上游万一出了空串也不该被当成有值。
    private static func nonEmpty(_ v: String?) -> String? {
        guard let v, !v.isEmpty else { return nil }
        return v
    }

    /// 裸对象成功 / 信封失败共用同一个 200，先探 `code` 字段分流。返回 nil 表示不是失败信封。
    private static func billingFailure(status: Int, data: Data) -> BillingError? {
        guard (200...299).contains(status) else {
            return BillingError(message: tr("recharge.failed"), kind: nil, outTradeNo: nil)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["code"] != nil else { return nil }
        let env = try? JSONDecoder().decode(BillingEnvelope.self, from: data)
        return BillingError(message: env?.message ?? tr("recharge.failed"),
                            kind: env?.kind, outTradeNo: env?.outTradeNo)
    }

    /// 下单响应的判读。抽成静态函数是为了让契约夹具直接驱动它
    /// （见 `ContractFixturesTests.testRechargeOrderDecodeFixtures`）。
    static func decodeRechargeOrder(status: Int, data: Data) throws -> RechargeOrder {
        if let failure = billingFailure(status: status, data: data) { throw failure }
        guard let raw = try? JSONDecoder().decode(RawRechargeOrder.self, from: data) else {
            throw BillingError(message: tr("recharge.failed"), kind: nil, outTradeNo: nil)
        }
        return RechargeOrder(present: raw.present, outTradeNo: raw.outTradeNo, amountCents: raw.amountCents,
                             codeUrl: nonEmpty(raw.codeUrl), qrCode: nonEmpty(raw.qrCode),
                             redirectUrl: nonEmpty(raw.redirectUrl), signData: nonEmpty(raw.signData),
                             paySig: nonEmpty(raw.paySig), signature: nonEmpty(raw.signature),
                             appAccountToken: nonEmpty(raw.appAccountToken))
    }

    /// 查单与确认到账共用同一个 RechargeStatus 形状（所以契约里 confirm 不另起夹具段）。
    static func decodeRechargeStatus(status: Int, data: Data) throws -> RechargeStatus {
        if let failure = billingFailure(status: status, data: data) { throw failure }
        guard let s = try? JSONDecoder().decode(RechargeStatus.self, from: data) else {
            throw BillingError(message: tr("recharge.failed"), kind: nil, outTradeNo: nil)
        }
        return s
    }

    /// POST /api/mobile/billing/recharge 的请求体。**channel=appstore 时不带 wxCode**
    /// （那是小程序虚拟支付换 openid + session_key 用的，内购这条路上根本没有微信）。
    /// idempotencyKey 由客户端生成并**先落盘再发**，服务端不代生成。
    static func rechargeBody(channel: String, productId: String,
                             amountCents: Int, idempotencyKey: String) -> [String: Any] {
        ["channel": channel, "productId": productId,
         "amountCents": amountCents, "idempotencyKey": idempotencyKey]
    }

    /// POST /api/mobile/billing/recharge/confirm 的请求体。
    /// outTradeNo **可省**：App 被杀后重放未完成交易时本地可能没存下单号，官网用 JWS 里的
    /// appAccountToken 反查 providerRef；省掉时这个键不能出现（不是空串）。
    static func confirmBody(outTradeNo: String?, signedTransaction: String) -> [String: Any] {
        var body: [String: Any] = ["signedTransaction": signedTransaction]
        if let outTradeNo, !outTradeNo.isEmpty { body["outTradeNo"] = outTradeNo }
        return body
    }

    private func jsonPost(_ path: String, body: [String: Any]) throws -> URLRequest {
        var req = Self.request(Backend.baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// 建单。此时**还没有付钱**：服务端只落一笔 pending 单并给回 appAccountToken。
    func billingRecharge(channel: String, productId: String,
                         amountCents: Int, idempotencyKey: String) async throws -> RechargeOrder {
        let req = try jsonPost("/api/mobile/billing/recharge",
                               body: Self.rechargeBody(channel: channel, productId: productId,
                                                       amountCents: amountCents, idempotencyKey: idempotencyKey))
        let (data, resp) = try await send(req)
        return try Self.decodeRechargeOrder(status: (resp as? HTTPURLResponse)?.statusCode ?? -1, data: data)
    }

    /// 把已验签交易的 JWS 交给服务端验签入账。**只有它回 paid 才可以 finish 这笔交易**——
    /// 提前 finish 等于用户付了钱而我们永久失去入账凭据（design §4 客户端顺序）。
    func billingRechargeConfirm(outTradeNo: String?, signedTransaction: String) async throws -> RechargeStatus {
        let req = try jsonPost("/api/mobile/billing/recharge/confirm",
                               body: Self.confirmBody(outTradeNo: outTradeNo, signedTransaction: signedTransaction))
        let (data, resp) = try await send(req)
        return try Self.decodeRechargeStatus(status: (resp as? HTTPURLResponse)?.statusCode ?? -1, data: data)
    }

    /// 查单。确认链路断了（比如 confirm 超时）时还能靠它看到到账结果。
    func billingRechargeStatus(outTradeNo: String) async throws -> RechargeStatus {
        var comps = URLComponents(url: Backend.baseURL.appendingPathComponent("/api/mobile/billing/recharge/status"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "outTradeNo", value: outTradeNo)]
        let req = Self.request(comps.url!)
        let (data, resp) = try await send(req)
        return try Self.decodeRechargeStatus(status: (resp as? HTTPURLResponse)?.statusCode ?? -1, data: data)
    }

    /// 把 multipart 信封写成磁盘文件，避免整份载荷进内存。
    /// 文本字段在前、文件在后——服务端流式解析时先拿到寻址字段。
    private nonisolated func makeMultipartFile(at dst: URL, boundary: String,
                                               fields: [(String, String)],
                                               source: URL, uploadName: String) throws {
        FileManager.default.createFile(atPath: dst.path, contents: nil)
        let h = try FileHandle(forWritingTo: dst)
        defer { try? h.close() }
        for (name, value) in fields {
            let part = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
            try h.write(contentsOf: Data(part.utf8))
        }
        let head = "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(uploadName)\"\r\nContent-Type: application/octet-stream\r\n\r\n"
        try h.write(contentsOf: Data(head.utf8))
        let r = try FileHandle(forReadingFrom: source)
        defer { try? r.close() }
        while let chunk = try r.read(upToCount: 1 << 20), !chunk.isEmpty {
            try h.write(contentsOf: chunk)
        }
        try h.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
    }

    // MARK: 传输

    /// 裸响应（无信封）的 GET。
    private func getRaw<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let req = Self.request(Backend.baseURL.appendingPathComponent(path))
        let (data, resp) = try await send(req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError(message: tr("error.server", ["code": String((resp as? HTTPURLResponse)?.statusCode ?? -1)]))
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw APIError(message: tr("error.badResponse")) }
    }

    /// 裸响应（无信封）的 POST。
    private func postRaw<T: Decodable>(_ path: String, body: [String: Any],
                                       as type: T.Type) async throws -> T {
        var req = Self.request(Backend.baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await send(req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError(message: tr("error.server", ["code": String((resp as? HTTPURLResponse)?.statusCode ?? -1)]))
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw APIError(message: tr("error.badResponse")) }
    }

    private func send(_ req: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await session.data(for: req) }
        catch { throw APIError(message: tr("error.network")) }
    }

    private func post<T: Decodable>(_ path: String,
                                    body: [String: String],
                                    as type: T.Type) async throws -> T? {
        var req = Self.request(Backend.baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            // 网络层失败要与业务失败分开说。用户看到「验证码错误」和看到
            // 「连不上服务器」会做完全不同的事。
            throw APIError(message: tr("error.network"))
        }

        guard let http = resp as? HTTPURLResponse else {
            throw APIError(message: tr("error.badResponse"))
        }
        guard (200...299).contains(http.statusCode) else {
            throw APIError(message: tr("error.server", ["code": String(http.statusCode)]))
        }

        let env: Envelope<T>
        do {
            env = try JSONDecoder().decode(Envelope<T>.self, from: data)
        } catch {
            throw APIError(message: tr("error.badResponse"))
        }
        guard env.code == 0 else {
            throw APIError(message: env.message ?? tr("error.generic"))
        }
        return env.data
    }
}
