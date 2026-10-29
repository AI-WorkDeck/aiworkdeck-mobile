import Foundation

/// 上传队列。
///
/// **串行，一次一条。** 现场是弱网，并发上传会让每一条都变慢、且失败面变大；
/// 一条一条走，失败只影响一条，进度也说得清。
///
/// 状态推进全部经过 EvidenceStore 落盘——进程被杀、App 被切走再回来，
/// 队列能从磁盘恢复，不依赖内存里的任何东西。
actor UploadQueue {
    static let shared = UploadQueue()

    private var running = false

    /// 进度回调，UI 层订阅。
    private var onChange: (@Sendable () async -> Void)?

    func configure(onChange: (@Sendable () async -> Void)?) {
        self.onChange = onChange
    }

    /// 失败后自动重试的退避：首败 60 秒，逐次翻倍，封顶 15 分钟；一旦传成即复位。
    private var autoRetryBackoff: TimeInterval = 60
    private var lastFailedRoundAt: Date?

    /// 启动一轮。已经在跑就直接返回，不排队叠加。
    func kick() async {
        guard !running else { return }
        running = true
        defer { running = false }

        // 滞留的「传输中」= 上一次进程死在上传半路（catch 没机会跑）。队列是串行 actor，
        // 走到这里时没有任何在途上传，所以此刻所有 moving 都是尸体——复位回 waiting
        // 重传，幂等键（clientMediaId）保证服务端不产生重复件。dev-board#241。
        let stale = (try? await EvidenceStore.shared.loadAll())?
            .filter { !$0.moveBlocksMutation && $0.state == .uploading } ?? []
        for s in stale {
            try? await EvidenceStore.shared.updateState(s.id, to: s.state.recovered(), progress: 0)
        }
        if !stale.isEmpty { await onChange?() }

        while true {
            // Unassigned captures stay local until the user explicitly moves them.
            guard let item = try? await EvidenceStore.shared.claimNextUpload(),
                  let target = item.project else { break }
            do {
                await onChange?()

                try await API.shared.upload(
                    item: item,
                    project: target,
                    fileName: Self.fileName(for: item)
                ) { _ in }

                // 进了中转区 ≠ 到了电脑：真正的 arrived 由 checkDelivered 按回执改
                try await EvidenceStore.shared.updateState(item.id, to: .uploaded, progress: 1)
                autoRetryBackoff = 60
                await onChange?()
            } catch {
                // 失败退回 failed 而不是 waiting：否则会立刻被下一轮捞起来无限重试，
                // 把弱网下本来能成的那几条也挤掉。重试由用户或下次启动触发。
                // 原因照实落盘——队列页要显示「为什么失败」，光一个红点用户没法自救。
                try? await EvidenceStore.shared.updateState(
                    item.id, to: .failed, progress: 0,
                    error: (error as? APIError)?.message ?? error.localizedDescription)
                lastFailedRoundAt = Date()
                autoRetryBackoff = min(autoRetryBackoff * 2, 15 * 60)
                await onChange?()
                break
            }
        }
    }

    /// 周期性自愈（AppModel 每分钟叫一次，回前台立刻叫）：滞留/待传直接续跑，
    /// 失败按退避自动重排——现场没人会盯着队列页点重试。dev-board#241。
    func autoKick() async {
        guard !running else { return }
        let items = (try? await EvidenceStore.shared.loadAll()) ?? []
        let hasFailed = items.contains { $0.state == .failed }
        let hasWork = items.contains { $0.state == .waiting || $0.state == .uploading }
        if hasFailed {
            let waited = lastFailedRoundAt.map { Date().timeIntervalSince($0) } ?? .infinity
            if waited >= autoRetryBackoff {
                await retryFailed()
                return
            }
        }
        if hasWork { await kick() }
    }

    /// 对停在中转区的影像查投递回执，桌面端确认落盘的改成 arrived。
    /// 查询失败静默返回——回执只是状态汇报，不该产生任何打扰。
    /// 返回未投递件的中转区到期时刻（键 clientMediaId 小写），队列页拿去做到期提醒。
    @discardableResult
    func checkDelivered() async -> [String: Date] {
        let uploaded = (try? await EvidenceStore.shared.loadAll())?
            .filter { !$0.moveBlocksMutation && $0.state == .uploaded } ?? []
        guard !uploaded.isEmpty else { return [:] }
        let ids = uploaded.map { $0.effectiveClientMediaId.uuidString.lowercased() }
        guard let status = try? await API.shared.mediaStatus(clientMediaIds: ids) else { return [:] }
        let byID = Dictionary(status.map { ($0.clientMediaId.lowercased(), $0) },
                              uniquingKeysWith: { _, last in last })
        var changed = false
        var expiry: [String: Date] = [:]
        for item in uploaded {
            let key = item.effectiveClientMediaId.uuidString.lowercased()
            guard let st = byID[key] else { continue }
            // 合并规则走契约迁移表（status_delivered / status_pending），这里不再手写 .arrived。
            let merged = item.state.applyingStatus(delivered: st.delivered,
                                                   waitingSeconds: st.waitingSeconds,
                                                   expiresAt: st.expiresAt)
            if merged.state != item.state {
                try? await EvidenceStore.shared.updateState(item.id, to: merged.state, progress: 1)
                changed = true
            }
            // CaptureItem 与 EvidenceStore 都没有 waitingSeconds / expiresAt 字段，等待信息不落盘；
            // 未投递件按 applyingStatus 回填的 expiresAt 解析成到期时刻，返给队列页做提醒。
            if let s = merged.expiresAt, let d = Self.parseExpiry(s) { expiry[key] = d }
        }
        if changed { await onChange?() }
        return expiry
    }

    /// expiresAt 是服务端给的 ISO 本地时间字符串（无时区、可能带小数秒）。
    /// 提醒是「天」级颗粒度，按本机时区解析足够。
    private static func parseExpiry(_ s: String) -> Date? {
        let trimmed = s.split(separator: ".").first.map(String.init) ?? s
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.date(from: trimmed)
    }

    /// 把失败的重新排回待传。用户手动点「重试」时调用。
    func retryFailed() async {
        let failed = (try? await EvidenceStore.shared.loadAll())?
            .filter { !$0.moveBlocksMutation && $0.state == .failed } ?? []
        for f in failed {
            try? await EvidenceStore.shared.updateState(f.id, to: .waiting, progress: 0)
        }
        await onChange?()
        await kick()
    }

    /// 文件名带上采集时刻，桌面端按名字排序即是时间序。
    /// 不用原始 UUID 当名字——律师在文件夹里看到一串十六进制没有任何意义。
    nonisolated static func fileName(for item: CaptureItem) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = f.string(from: item.capturedAt)
        let (prefix, ext) = switch item.kind {
        case .photo: (tr("file.prefix.media"), "jpg")
        case .video: (tr("file.prefix.media"), "mov")
        case .audio: (tr("file.prefix.audio"), "m4a")
        }
        let short = item.id.uuidString.prefix(4)
        return "\(prefix)-\(stamp)-\(short).\(ext)"
    }
}
