import XCTest
@testable import Workdeck

/// 账号区域（dev-board#837）：解析缺省 / 已存、主机映射、按区域可用的登录方式。
final class AccountRegionTests: XCTestCase {
    func testWebsiteFlowPreservesLegacyEmailIntentWithoutIdentityInURL() {
        for flow in ["register", "reset"] {
            XCTAssertEqual(accountFlowURL(region: .cn, method: .email, flow: flow).absoluteString,
                           "https://aiworkdeck.com/zh/account?flow=\(flow)&legacyEmail=1")
            XCTAssertEqual(accountFlowURL(region: .cn, method: .phone, flow: flow).absoluteString,
                           "https://aiworkdeck.com/zh/account?flow=\(flow)")
            XCTAssertEqual(accountFlowURL(region: .intl, method: .email, flow: flow).absoluteString,
                           "https://workdeck.ai/en/account?flow=\(flow)")
        }
        XCTAssertEqual(accountFlowURL(region: .cn, method: .email, flow: "reset&email=private@example.invalid").query,
                       "flow=register&legacyEmail=1")
    }

    private var defaults: UserDefaults!
    private let suite = "AccountRegionTests"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        super.tearDown()
    }

    /// 存量已登录用户没有这个键：必须落到大陆站，零迁移。
    func testMissingKeyFallsBackToMainland() {
        XCTAssertNil(defaults.string(forKey: AccountRegion.defaultsKey))
        XCTAssertEqual(AccountRegion.load(from: defaults), .cn)
    }

    func testStoredValueIsRead() {
        AccountRegion.save(.intl, to: defaults)
        XCTAssertEqual(defaults.string(forKey: "accountRegion"), "intl")
        XCTAssertEqual(AccountRegion.load(from: defaults), .intl)

        AccountRegion.save(.cn, to: defaults)
        XCTAssertEqual(defaults.string(forKey: "accountRegion"), "cn")
        XCTAssertEqual(AccountRegion.load(from: defaults), .cn)
    }

    /// 读不懂的值按缺省处理，不崩、不猜。
    func testUnknownStoredValueFallsBackToMainland() {
        defaults.set("eu", forKey: AccountRegion.defaultsKey)
        XCTAssertEqual(AccountRegion.load(from: defaults), .cn)
        XCTAssertEqual(AccountRegion.resolve(""), .cn)
        XCTAssertEqual(AccountRegion.resolve(nil), .cn)
    }

    func testHostMapping() {
        XCTAssertEqual(AccountRegion.cn.baseURL.absoluteString, "https://addin.aiworkdeck.com")
        XCTAssertEqual(AccountRegion.intl.baseURL.absoluteString, "https://addin.workdeck.ai")
    }

    /// 标签键必须在契约词典里，否则界面上会露出键名。
    func testLabelKeysExistInContract() {
        for r in AccountRegion.allCases {
            XCTAssertNotNil(ContractStrings.table[r.labelKey], r.labelKey)
        }
        XCTAssertNotNil(ContractStrings.table["login.region.intlHint"])
        XCTAssertNotNil(ContractStrings.table["settings.region"])
    }

    /// Backend.baseURL 每次现读当前区域（走 .standard，测完恢复原值）。
    func testBackendFollowsCurrentRegion() {
        let saved = UserDefaults.standard.object(forKey: AccountRegion.defaultsKey)
        defer { UserDefaults.standard.set(saved, forKey: AccountRegion.defaultsKey) }

        AccountRegion.current = .intl
        XCTAssertEqual(Backend.baseURL.host, "addin.workdeck.ai")
        AccountRegion.current = .cn
        XCTAssertEqual(Backend.baseURL.host, "addin.aiworkdeck.com")
    }

    func testLoginMethodsPerRegion() {
        XCTAssertEqual(LoginMethod.available(in: .cn), [.phone, .email])
        XCTAssertEqual(LoginMethod.available(in: .intl), [.email])
    }

    /// 大陆区保持原行为（大陆包默认手机号）；国际区不管包名一律邮箱。
    func testDefaultMethodPerRegion() {
        XCTAssertEqual(LoginMethod.defaultMethod(in: .cn, bundleID: "com.aiworkdeck.mobile.cn"), .phone)
        XCTAssertEqual(LoginMethod.defaultMethod(in: .cn, bundleID: "com.aiworkdeck.mobile"), .email)
        XCTAssertEqual(LoginMethod.defaultMethod(in: .intl, bundleID: "com.aiworkdeck.mobile.cn"), .email)
        XCTAssertEqual(LoginMethod.defaultMethod(in: .intl, bundleID: nil), .email)
    }

    /// 国际站计费未开通（dev-board#664）：余额与充值只在大陆区。
    func testBillingOnlyInMainland() {
        XCTAssertTrue(AccountRegion.cn.billingEnabled)
        XCTAssertFalse(AccountRegion.intl.billingEnabled)
    }

    // MARK: 语言跟随区域（第二版）

    func testLocaleFollowsRegion() {
        XCTAssertEqual(L10n.locale(for: .cn), "zh-Hans")
        XCTAssertEqual(L10n.locale(for: .intl), "en")

        defer { L10n.locale = "zh-Hans" }
        L10n.apply(region: .intl)
        XCTAssertEqual(L10n.locale, "en")
        XCTAssertEqual(tr("login.region.intl"), "Global")
        XCTAssertEqual(tr("settings.region"), "Account region")
        L10n.apply(region: .cn)
        XCTAssertEqual(L10n.locale, "zh-Hans")
        XCTAssertEqual(tr("login.region.intl"), "海外版")
    }

    /// 语言是可观察状态：界面在 body 里调 tr() 就会被登记为依赖，切区域当场重绘。
    func testLocaleChangeIsObservable() {
        defer { L10n.locale = "zh-Hans" }
        L10n.locale = "zh-Hans"
        let fired = expectation(description: "locale change observed")
        withObservationTracking {
            _ = tr("login.title")
        } onChange: {
            fired.fulfill()
        }
        L10n.apply(region: .intl)
        wait(for: [fired], timeout: 1)
    }

    /// 界面上用到的日期模板跟着界面语言走，而不是设备语言。
    func testDayTitleFollowsLocale() {
        defer { L10n.locale = "zh-Hans" }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let day = cal.date(from: DateComponents(year: 2026, month: 9, day: 2, hour: 10))!
        L10n.apply(region: .intl)
        XCTAssertEqual(tr("library.dayTitle", ["m": "9", "d": "2", "n": "3"]), "9/2 · 3 items")
        XCTAssertEqual(RelativeTime.short(day.addingTimeInterval(-90), now: day), "1 min ago")
        L10n.apply(region: .cn)
        XCTAssertEqual(RelativeTime.short(day.addingTimeInterval(-90), now: day), "1 分钟前")
    }

    /// 每个请求带 X-App-Language：海外版 en-US，大陆版 zh-CN。
    func testRequestCarriesAppLanguage() {
        XCTAssertEqual(AccountRegion.cn.appLanguage, "zh-CN")
        XCTAssertEqual(AccountRegion.intl.appLanguage, "en-US")

        let saved = UserDefaults.standard.object(forKey: AccountRegion.defaultsKey)
        defer { UserDefaults.standard.set(saved, forKey: AccountRegion.defaultsKey) }
        AccountRegion.current = .intl
        let intlReq = API.request(Backend.baseURL.appendingPathComponent("/api/mobile/projects"))
        XCTAssertEqual(intlReq.url?.host, "addin.workdeck.ai")
        XCTAssertEqual(intlReq.value(forHTTPHeaderField: "X-App-Language"), "en-US")
        AccountRegion.current = .cn
        let cnReq = API.request(Backend.baseURL.appendingPathComponent("/api/mobile/projects"))
        XCTAssertEqual(cnReq.url?.host, "addin.aiworkdeck.com")
        XCTAssertEqual(cnReq.value(forHTTPHeaderField: "X-App-Language"), "zh-CN")
    }

    /// 切区域要清掉上一区域的已选项目（含持久化），登录新区域后落到项目选择页，
    /// 不会带着上一账号的项目进首页。
    @MainActor
    func testSwitchRegionClearsSelectedProject() {
        let d = UserDefaults.standard
        let savedRegion = d.object(forKey: AccountRegion.defaultsKey)
        let savedProject = d.object(forKey: "selectedRelayProject")
        defer {
            d.set(savedRegion, forKey: AccountRegion.defaultsKey)
            d.set(savedProject, forKey: "selectedRelayProject")
            L10n.locale = "zh-Hans"
        }

        let model = AppModel()
        let p = RelayProject(deviceId: "mac-cn", deviceName: nil, key: "k1", name: "大陆项目")
        model.selectedProject = p
        model.project = FieldProject(id: p.id, name: p.name, archivePath: "x")
        model.cloudExpiry = ["abc": Date()]
        XCTAssertNotNil(d.data(forKey: "selectedRelayProject"))

        model.switchRegion(to: .intl)

        XCTAssertNil(model.selectedProject)
        XCTAssertNil(d.data(forKey: "selectedRelayProject"), "持久化的已选项目也要清掉")
        XCTAssertEqual(model.project.id, "local")
        XCTAssertTrue(model.cloudExpiry.isEmpty)
        XCTAssertEqual(AccountRegion.current, .intl)
        XCTAssertEqual(L10n.locale, "en")
    }
}
