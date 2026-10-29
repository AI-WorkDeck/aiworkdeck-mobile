import Foundation

/// 一张影像在「拍摄 → 抵达电脑」这条链上的位置。名称、别名、映射、文案键全部来自 contract/（ContractStates）。
enum TransferState: String, Codable, Sendable, CaseIterable {
    case waiting, uploading, uploaded, arrived, failed

    /// 旧版本落盘的 `moving` 按契约别名解码为 uploading；编码始终用正式名。
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        let canonical = ContractStates.aliases[raw] ?? raw
        guard let s = TransferState(rawValue: canonical) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "未知状态 \(raw)"))
        }
        self = s
    }

    /// 短形式，行标签用。长形式见 detail。
    var caption: String { tr(ContractStates.stateTextKey[rawValue]!) }
    /// 长形式，有空间的行用（uploaded 出「已暂存 · 等待桌面端接收」）。
    var detail: String { tr(ContractStates.stateDetailKey[rawValue]!) }
    var whereItIs: String { tr(ContractStates.whereKey[rawValue]!) }
    var phase: TransferPhase { TransferPhase(rawValue: ContractStates.phaseOf[rawValue]!)! }

    /// 迁移表驱动。无规则 → nil（非法迁移）；有规则但 guard 不满足 → 原态。
    func next(_ event: TransferEvent, attempts: Int = 0) -> TransferState? {
        let rules = ContractStates.transitions.filter { $0.from == rawValue && $0.event == event.rawValue }
        if rules.isEmpty { return nil }
        for r in rules where TransferState.guardOK(r.guard, attempts: attempts) { return TransferState(rawValue: r.to)! }
        return self
    }

    /// 冷启动回拨 = app_launch 事件。iOS 暂无 attempts 计数，调用方传 0。
    func recovered(attempts: Int = 0) -> TransferState { next(.appLaunch, attempts: attempts) ?? self }

    /// status 轮询只对 uploaded 有意义；delivered 清掉等待字段，pending 回填。
    func applyingStatus(delivered: Bool, waitingSeconds: Int64, expiresAt: String?)
        -> (state: TransferState, waitingSeconds: Int64?, expiresAt: String?) {
        guard self == .uploaded else { return (self, nil, nil) }
        if delivered { return (next(.statusDelivered) ?? self, nil, nil) }
        return (next(.statusPending) ?? self, waitingSeconds, expiresAt)
    }

    private static func guardOK(_ g: String?, attempts: Int) -> Bool {
        guard let g else { return true }
        if g == "attempts <= maxAutoRetries" { return attempts <= ContractStates.maxAutoRetries }
        preconditionFailure("未知 guard: \(g)")
    }
}

enum TransferEvent: String, Sendable {
    case kick, http2xx = "http_2xx", httpError = "http_error", networkError = "network_error"
    case retryManual = "retry_manual", retryAuto = "retry_auto"
    case statusDelivered = "status_delivered", statusPending = "status_pending", appLaunch = "app_launch"
}

enum TransferPhase: String, CaseIterable, Sendable {
    case uploading, staged, landed
    var caption: String { tr(ContractStates.phaseLabelKey[rawValue]!) }
}

enum MediaKind: String, Codable, Sendable {
    case photo
    case video
    case audio
}

/// 取证归档信息。
///
/// 当前做到「归档级」：时间、地点、设备、SHA-256，保证「没被改过」可自证。
/// `tsaToken` 是留给「证据级」的接口 —— 接可信时间戳时把它填上，数据结构不用动。
struct CaptureManifest: Codable, Sendable {
    /// 幂等键。弱网重传、进程被杀重启，都靠它避免产生重复文件。
    let clientMediaId: UUID
    let sha256: String
    /// 设备时钟。与 serverCapturedAt 并存，两者不一致本身就是需要记录的事实。
    let capturedAt: Date
    /// 服务端在收件时盖的时间，中转区回写
    var serverReceivedAt: Date?
    let latitude: Double?
    let longitude: Double?
    /// 定位精度（米）。没有精度的坐标在质证时说明不了问题。
    let horizontalAccuracy: Double?
    let deviceModel: String
    let osVersion: String
    let appVersion: String
    /// 是否强制来自相机（而非相册导入）。取证的前提。
    let fromCamera: Bool
    /// 可信时间戳。当前恒为 nil，接 TSA 后填入。
    var tsaToken: String?
}

struct CaptureItem: Identifiable, Sendable {
    let id: UUID
    let kind: MediaKind
    var state: TransferState
    let manifest: CaptureManifest
    /// 应用沙盒内的原图路径。不进系统相册 —— 手机丢了、相册被翻，尽调材料不在里面。
    let localURL: URL
    /// 上传进度 0...1，仅 .uploading 时有意义
    var progress: Double
    /// 上次失败原因。队列页要显示「为什么失败」——只给一个红点，
    /// 用户既不知道该重试还是该找人，也不知道是自己网络的问题还是我们的问题。
    var lastError: String?
    /// 是否已存进系统相册（开关打开时）。避免重复写入相册。
    var savedToAlbum: Bool
    /// 归档去向。拍摄那一刻的选中项目，之后切项目不影响它。
    /// nil 表示未归类，等待用户显式指定。
    var project: RelayProject?
    /// Even a failed request may have reached the server. Never silently reroute
    /// its idempotency key after the first upload attempt.
    var uploadAttempted = false
    /// Watch recordings and moved remote receipts must stay bound to their owner.
    var watchAccountBinding: String? = nil
    var archiveMove: ArchiveMove? = nil
    var remoteClientMediaId: UUID? = nil
    var effectiveClientMediaId: UUID { remoteClientMediaId ?? manifest.clientMediaId }
    var moveBlocksMutation: Bool { archiveMove?.blocksMutation == true }
    var canMoveToProject: Bool { !moveBlocksMutation && !uploadAttempted && (state == .waiting || state == .failed) }
    var canRequestArchiveMove: Bool { !moveBlocksMutation && project != nil && uploadAttempted && state != .uploading }
    var queueState: TransferState {
        guard let move = archiveMove, move.status != .done else { return state }
        return move.status == .failed ? .failed : .uploading
    }
    var queueCaption: String { archiveMove.flatMap { $0.status == .done ? nil : $0.status.caption } ?? state.caption }
    var queueError: String? {
        if let move = archiveMove, move.status != .done { return move.lastError }
        return lastError
    }

    var capturedAt: Date { manifest.capturedAt }

    /// 图集分组用的项目键。旧记录无项目 → "unknown"。
    var projectID: String { project?.id ?? LibraryProject.unknownID }
}

/// 三段各有多少件。failed 是 uploading 的子集，用来在桶上标「含 N 失败」。
struct TransferTally: Sendable, Equatable {
    var uploading: Int
    var failed: Int
    var staged: Int
    var landed: Int

    var total: Int { uploading + staged + landed }

    static let zero = TransferTally(uploading: 0, failed: 0, staged: 0, landed: 0)

    static func of(_ items: [CaptureItem]) -> TransferTally {
        var t = TransferTally.zero
        for i in items {
            switch i.state.phase {
            case .uploading: t.uploading += 1
            case .staged: t.staged += 1
            case .landed: t.landed += 1
            }
            if i.state == .failed { t.failed += 1 }
        }
        return t
    }
}

/// 图集里的「一个项目」。与 RelayProject 的区别：多一个「未知项目」桶给旧记录。
struct LibraryProject: Identifiable, Hashable, Sendable {
    static let unknownID = "unknown"
    let id: String
    let name: String

    static let unknown = LibraryProject(id: unknownID, name: tr("library.unknownProject"))
    init(id: String, name: String) { self.id = id; self.name = name }
    init(_ p: RelayProject) { self.init(id: p.id, name: p.name) }
}

struct FieldProject: Identifiable, Sendable {
    let id: String
    let name: String
    /// 归档去向的展示文案，例如「现场影像 / 2026-08-17」
    let archivePath: String
}

/// 桌面端连接状态。
/// 桌面端是 Electron，关掉就不轮询了 —— 所以「照片自动归档」的前提是它开着。
/// 界面必须把这件事说清楚，改变不了就不要藏着。
struct DesktopLink: Sendable {
    var isOnline: Bool
    var lastSyncedAt: Date?
    var deviceName: String?
}
