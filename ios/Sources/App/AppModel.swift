import Foundation
import SwiftUI

/// 全局状态。界面只读它，写入一律经过这里，保证 store 与 UI 不会各说各话。
@MainActor
@Observable
final class AppModel {
    // 用 AppModel.today 而不是 Self.today：类的存储属性初始化式里不能引用
    // 协变的 Self，编译器直接拒。
    var project = FieldProject(
        id: "local",
        name: tr("project.none"),
        archivePath: tr("archive.path", ["date": AppModel.today])
    )
    var items: [CaptureItem] = []

    /// 当前项目的键。图集与计数只看它。
    var currentProjectID: String { selectedProject?.id ?? LibraryProject.unknownID }
    var currentItems: [CaptureItem] { LibraryGrouping.items(items, in: currentProjectID, project: selectedProject) }
    /// 三段计数，只数当前项目——进度跟着项目走。
    var tally: TransferTally { TransferTally.of(currentItems) }
    /// 别的项目里还没落盘的件数。队列页末尾提一句，免得它们被完全藏起来。
    var otherPendingCount: Int {
        let currentIDs = Set(currentItems.map(\.id))
        return items.filter { !currentIDs.contains($0.id) && $0.state != .arrived }.count
    }
    /// 桌面端连接。还没做配对，先恒定离线——**不要为了界面好看假装在线**，
    /// 那会让人以为照片已经在往电脑走。
    var link = DesktopLink(isOnline: false, lastSyncedAt: nil, deviceName: nil)

    /// 当前账号。nil = 未登录，界面走登录页。
    var account: AccountUser?
    var isSignedIn: Bool { account != nil }
    /// 启动时先按 Keychain 里有没有会话决定初屏，避免登录页闪一下再跳走。
    private(set) var didRestore = false

    static var today: String {
#if DEBUG
        // 截图模式把「今天」钉在归档日期上，否则水印上的真实日期与归档路径对不上
        if Shot.isOn { return Shot.dateString }
#endif
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private(set) var accountGeneration = UUID()
    var backupConsent: BackupConsent?
    var backupError: String?
    var showBackupPrompt = false

    func refreshBackupConsent(promptIfNeeded: Bool = true) async {
        guard isSignedIn else { return }
#if DEBUG
        if Shot.isOn || ProcessInfo.processInfo.arguments.contains("-AWDRecordingUITest") { return }
#endif
        let generation = accountGeneration
        do {
            let consent = try await workspaceFiles().backupConsent()
            guard generation == accountGeneration else { return }
            backupConsent = consent; backupError = nil
            if promptIfNeeded { showBackupPrompt = !consent.decided }
        } catch {
            guard generation == accountGeneration else { return }
            backupError = tr("backup.error")
        }
    }

    func setBackupConsent(enabled: Bool) async -> Bool {
        let generation = accountGeneration
        do {
            let consent = try await workspaceFiles().setBackupConsent(enabled: enabled)
            guard generation == accountGeneration else { return false }
            backupConsent = consent; backupError = nil; showBackupPrompt = !consent.decided
            return consent.decided
        } catch {
            guard generation == accountGeneration else { return false }
            backupError = tr("backup.error")
            return false
        }
    }

    private var filesClient: (any ProjectFilesServing)?

    func workspaceFiles() -> any ProjectFilesServing {
        if let filesClient { return filesClient }
        let client = ProjectFilesService(context: ProjectFilesContext(
            baseURL: Backend.baseURL, sessionID: SessionStore.current ?? "",
            language: AccountRegion.current.appLanguage))
        filesClient = client
        return client
    }

    private func closeWorkspaceFiles() {
        accountGeneration = UUID()
        backupConsent = nil; backupError = nil; showBackupPrompt = false
        let client = filesClient
        filesClient = nil
        Task { await client?.close() }
    }

    // MARK: - 账号

    /// 选中的归档目标。nil = 即时采集，资料保留在未归类。
    /// 存 UserDefaults 就够——项目条目不是凭据，泄露它没有意义。
    /// （旧版存的是 Int 型云端项目 id，键 selectedProjectId；目录镜像的 key 是
    /// 桌面机本地 id，两个命名空间不通，升级后旧选择一律作废、回到选择页。）
    var selectedProject: RelayProject? {
        didSet {
            if let p = selectedProject, let data = try? JSONEncoder().encode(p) {
                UserDefaults.standard.set(data, forKey: "selectedRelayProject")
            } else {
                UserDefaults.standard.removeObject(forKey: "selectedRelayProject")
            }
        }
    }

    func didLogin(_ result: LoginResult) async {
        closeWorkspaceFiles()
        selectedProject = nil
        account = result.user
        await refresh()
    }

    func selectProject(_ p: RelayProject) async {
        selectedProject = p
        project = FieldProject(id: p.id, name: p.name,
                               archivePath: tr("archive.path", ["date": AppModel.today]))
#if DEBUG
        if WorkspaceUITestSeed.isOn { return }
#endif
        await UploadQueue.shared.configure() { [weak self] in
            await self?.refresh()
        }
        kickUpload()
    }

    /// 拍完立刻踢一脚队列。不等用户手动点上传——现场没人会记得点。
    func kickUpload() {
#if DEBUG
        if Shot.isOn || WorkspaceUITestSeed.isOn || ProcessInfo.processInfo.arguments.contains("-AWDRecordingUITest") { return }
#endif
        Task { await UploadQueue.shared.kick() }
    }

    func retryFailedUploads() {
        Task { await UploadQueue.shared.retryFailed() }
    }

    /// 单条重试。队列页每行都有，不用为了一条失败去点「全部重试」。
    func retry(_ item: CaptureItem) {
        Task {
            try? await EvidenceStore.shared.updateState(item.id, to: .waiting, progress: 0)
            await refresh()
            await UploadQueue.shared.kick()
        }
    }

    func captureWithoutProject() {
        selectedProject = nil
        project = FieldProject(id: "local", name: tr("project.none"),
                               archivePath: tr("archive.path", ["date": AppModel.today]))
    }

    func move(_ item: CaptureItem, to project: RelayProject) async throws {
        try await EvidenceStore.shared.moveToProject(item.id, project)
        await refresh()
        kickUpload()
    }

    /// 登录页切账号区域（dev-board#837）。两个区域是两套账号体系：上一区域的项目目录是另一个
    /// 账号的桌面端推上来的，拿到新区域用等于把新拍的影像寻址到一台新账号不认识的电脑上。
    /// 所以切区域时把跟上一账号项目目录挂钩的状态全部清掉——已选项目（含持久化）、首页项目名、
    /// 中转区到期表；未归类资料不会自动匹配到新区域的项目。
    /// 已拍影像各自记着拍摄时的项目，不动（队列行为见报告，沿用现状）。
    func switchRegion(to region: AccountRegion) {
        closeWorkspaceFiles()
        AccountRegion.current = region
        L10n.apply(region: region)
        selectedProject = nil
        project = FieldProject(id: "local", name: tr("project.none"),
                               archivePath: tr("archive.path", ["date": AppModel.today]))
        cloudExpiry = [:]
    }

    /// 用户在图集里多选删除：原图与记录一起删。
    func delete(ids: [UUID]) async {
        await EvidenceStore.shared.delete(ids: ids)
        await refresh()
    }

    /// 未投递件的中转区到期时刻（键 clientMediaId 小写）。队列页做到期提醒用。
    var cloudExpiry: [String: Date] = [:]

    /// 查投递回执：停在中转区的影像被桌面端取走后改成「已抵达」。
    func checkDelivered() {
#if DEBUG
        if Shot.isOn { return }
#endif
        Task {
            cloudExpiry = await UploadQueue.shared.checkDelivered()
            await refresh()
        }
    }

    func signOut() {
        closeWorkspaceFiles()
        API.shared.logout()
        selectedProject = nil
        project = FieldProject(id: "local", name: tr("project.none"),
                               archivePath: tr("archive.path", ["date": AppModel.today]))
        account = nil
        // **不清本地影像。** 退出登录不等于放弃已经拍到的东西——
        // 现场是不可复现的，登出就删是灾难性的默认。
    }

    /// 注销账号。删的是**云端**的账号与数据；手机本地的影像不动——理由同 signOut，
    /// 现场不可复现，替用户销毁原图不是清理是毁证。界面上写明了这一点。
    ///
    /// App Store 审核指南 5.1.1(v) 要求支持注册的 App 必须在 App 内提供这个入口。
    func deleteAccount() async throws {
        try await API.shared.deleteAccount()
        closeWorkspaceFiles()
        account = nil
        selectedProject = nil
    }

    func refresh() async {
#if DEBUG
        // 截图模式的画面全在内存里（Shot.items），本地仓库是空的——
        // 这里照常读一次就会把演示数据冲成空屏（队列页每 20 秒问一次回执，第一下就冲没了）。
        if Shot.isOn { return }
#endif
        do {
            items = try await EvidenceStore.shared.loadAll()
        } catch {
            // 读不出来不该清空界面——宁可显示上一次的状态，也不要让用户以为照片没了
        }
    }

#if DEBUG
    /// 只给截图流程用：跳过登录与网络，直接摆出 Shot 的画面。
    private func seedForScreenshots() {
        account = Shot.account
        // 项目要和 Shot.items 里每件记的项目一致：计数与图集现在都按件内项目派生，
        // 对不上就是一屏「0 / 0 / 0」
        selectedProject = Shot.project
        project = Shot.field
        items = Shot.items
        link = Shot.link
        didRestore = true
    }
#endif

    func bootstrap() async {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-AWDLoginUITest") {
            didRestore = true
            return
        }
        if WorkspaceUITestSeed.isOn {
            L10n.locale = "en"
            account = Shot.account
            selectedProject = nil
            filesClient = WorkspaceUITestSeed()
            AudioRecorderService.shared.onStored = { [weak self] in await self?.refresh() }
            items = []
            didRestore = true
            return
        }

        if ProcessInfo.processInfo.arguments.contains("-AWDRecordingUITest") {
            L10n.locale = "en"
            account = Shot.account
            selectedProject = Shot.project
            project = Shot.field
            AudioRecorderService.shared.onStored = { [weak self] in await self?.refresh() }
            didRestore = true
            await refresh()
            return
        }

        // 上架截图用的假状态。**只编进 Debug**——截图本来就不需要 Release 包，
        // 而把演示数据留在发行二进制里，早晚会有人在真机上撞进这条分支。
        if Shot.isOn {
            seedForScreenshots()
            return
        }
#endif
        // Keychain 里有会话就直接进主界面。这里只做「有没有」的判断，
        // 会话是否还有效由第一次真实请求的 401 来发现——启动时多打一次
        // 网络请求会让离线开 App 卡在转圈，而离线拍照恰恰是这个 App 的主场景。
        if SessionStore.current != nil, account == nil {
            account = AccountUser(id: 0, username: "", displayName: "", avatarUrl: "", role: "USER")
        }
        // 旧版的 Int 键作废（命名空间已换），顺手清掉
        UserDefaults.standard.removeObject(forKey: "selectedProjectId")
        if let data = UserDefaults.standard.data(forKey: "selectedRelayProject"),
           let saved = try? JSONDecoder().decode(RelayProject.self, from: data) {
            selectedProject = saved
            project = FieldProject(id: saved.id, name: saved.name,
                                   archivePath: tr("archive.path", ["date": AppModel.today]))
        }
        await UploadQueue.shared.configure() { [weak self] in await self?.refresh() }
        AudioRecorderService.shared.onStored = { [weak self] in
            await self?.refresh()
            self?.kickUpload()
        }
        didRestore = true
        await AudioRecorderService.shared.recoverPending()
        try? await EvidenceStore.shared.sweepOrphans()
        await refresh()
        // 上次没传完的，启动就接着传；停在中转区的顺手查一次回执
        if isSignedIn {
            await UploadQueue.shared.kick()
            cloudExpiry = await UploadQueue.shared.checkDelivered()
            await refresh()
        }
        // 上传自愈心跳（dev-board#241）：滞留的「传输中」与失败件不能等用户来点，
        // 现场拍完手机就揣兜里了——每分钟自动续传，失败按退避重试
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if self.isSignedIn { await UploadQueue.shared.autoKick() }
            }
        }
    }

    func store(data: Data, kind: MediaKind, at: Date, location: (lat: Double, lon: Double, accuracy: Double)?, project: RelayProject?) async {
        do {
            _ = try await EvidenceStore.shared.save(
                data: data, kind: kind, capturedAt: at,
                location: location, device: Device.facts, project: project
            )
            await refresh()
            kickUpload()
            await saveToAlbumIfEnabled()
        } catch {
            lastError = tr("error.saveFailed", ["reason": error.localizedDescription])
        }
    }

    /// 存进系统相册（开关打开时）。**与上传彼此独立**——
    /// 相册存不进去不该影响上传，反之亦然，两条链任何一条断了另一条都要继续走。
    private func saveToAlbumIfEnabled() async {
        guard Prefs.saveToAlbum else { return }
        // 录音不进相册：PhotoKit 没有音频资产，混进来只会在这个循环里反复空转。
        let pending = items.filter { !$0.savedToAlbum && $0.kind != .audio }
        for item in pending {
            do {
                try await AlbumSaver.save(url: item.localURL, kind: item.kind)
                try? await EvidenceStore.shared.markSavedToAlbum(item.id)
            } catch {
                // 不打断、不弹窗。相册失败最常见的原因是没给权限，
                // 设置页里已经把这件事说清楚了，这里再弹一次是噪音。
                albumWarning = error.localizedDescription
            }
        }
        await refresh()
    }

    var albumWarning: String?
    var lastError: String?
}
