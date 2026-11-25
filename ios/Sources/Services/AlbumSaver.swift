import Foundation
import Photos

/// 存进系统相册。
///
/// **这是对「原图只留在应用沙盒」那条设计的反转，由维护者 2026-08-17 拍板。**
/// 原设计的理由是：手机丢了、相册被翻，尽调材料不该躺在相册里。
/// 现在做成开关，把这个权衡摆在设置页上让用户每次都是知情选择。
///
/// **只做「添加」，不建、不找自定义相册。** 旧实现想把影像归进一个自建的
/// 「AI WorkDeck」相册，但 `PHAssetCollection.fetchAssetCollections` 与
/// `creationRequestForAssetCollection` 都是读写级操作：在只拿到 addOnly 授权的
/// 情况下调用，系统会再弹一次「完整访问」授权，而这个 App 从来没有声明
/// `NSPhotoLibraryUsageDescription`——TCC 对缺少用途说明的授权请求的处理是
/// 直接杀进程。表现就是「第一次按快门即闪退」，TestFlight 上没有任何日志
/// （dev-board#101，iPhone 17 Pro Max / iOS 26 实测）。
/// 要恢复自建相册必须同时声明读权限并申请 .readWrite，那是产品决策，不在这里偷偷做。
enum AlbumSaver {
    enum SaveError: UserFacingError {
        case denied
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .denied: tr("album.denied")
            case .failed(let m): m
            }
        }
    }

    /// 只申请「添加」权限（addOnly），不要读权限——
    /// 这个 App 没有任何理由读用户的相册，多要一分权限就多一分解释成本。
    static func ensureAuthorized() async -> Bool {
        let s = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if s == .authorized || s == .limited { return true }
        if s == .notDetermined {
            return await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized
        }
        return false
    }

    static func save(url: URL, kind: MediaKind) async throws {
        // PhotoKit 没有音频资产，且取证录音本不该进相册——直接返回，不报错。
        // 拿 m4a 去 creationRequestForAssetFromVideo 会静默失败或产生废资产。
        switch kind {
        case .audio: return
        case .photo, .video: break
        }
        guard await ensureAuthorized() else { throw SaveError.denied }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                if kind == .photo {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                } else {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }
            }
        } catch {
            throw SaveError.failed(userFacingMessage(for: error, fallback: tr("error.generic")))
        }
    }
}

/// 用户偏好。项目 id 与开关这类不是凭据，UserDefaults 足够。
enum Prefs {
    private static let albumKey = "saveToPhotoAlbum"

    /// 默认**开**：维护者明确要求影像进相册。
    /// 关掉后已经进相册的不会被移除——那是用户的相册，App 不该替他删东西。
    static var saveToAlbum: Bool {
        get {
            UserDefaults.standard.object(forKey: albumKey) as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: albumKey) }
    }
}
