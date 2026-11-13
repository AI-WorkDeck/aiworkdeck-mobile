package com.aiworkdeck.mobile.services

import com.aiworkdeck.mobile.model.CaptureItem
import com.aiworkdeck.mobile.model.RelayProject

/** UploadQueue 依赖的最小上传契约，方便单测用 FakeUploader 顶替 Backend。 */
interface Uploader {
    suspend fun upload(item: CaptureItem, project: RelayProject, fileName: String, onProgress: (Double) -> Unit): UploadResult
    suspend fun mediaStatus(ids: List<String>): List<MediaStatus>
    /** Whether the cloud scratch project (临时项目) may receive uploads right now. */
    suspend fun persistentCloudWritable(): Boolean = true
}

/**
 * Backend 的瘦适配层：把 CaptureItem + RelayProject + 已算好的文件名，拼成 Backend.upload
 * 要的六个字段。deviceId 取项目所在电脑（云端项目为 "cloud"），与 iOS 相同。
 */
class BackendUploader(private val backend: Backend, private val organizationPrefs: Prefs? = null) : Uploader {
    override suspend fun persistentCloudWritable(): Boolean = backend.persistentCloudWritable()
    override suspend fun upload(item: CaptureItem, project: RelayProject, fileName: String, onProgress: (Double) -> Unit): UploadResult {
        val active = backend.accountSnapshot()
        val scope = active.personalAccountScope()
        val organize = organizationPrefs?.organizeCaptures(scope) == true
        val result = active.upload(
            file = item.localFile,
            // 收件方是项目所在的那台电脑（云端项目为 "cloud"），与 iOS 相同；
            // 曾误传本机安装 ID，服务端按它入箱，桌面端永远取不到（2026-11-12 修）。
            deviceId = project.deviceId,
            projectKey = project.key,
            clientMediaId = item.effectiveClientMediaId,
            fileName = fileName,
            mediaType = item.kind.mediaType,
            capturedAt = item.manifest.capturedAt,
            organize = organize,
            onProgress = onProgress,
        )
        if (item.localFile.exists() && (organize || (result.organization != null && result.organization.state != "disabled"))) {
            organizationPrefs?.let { prefs ->
                synchronized(prefs) {
                    if (scope != null && scope == backend.personalAccountScope())
                        prefs.saveOrganization(scope, item.effectiveClientMediaId, result.organization ?: CaptureOrganization("unknown"))
                }
            }
        }
        return result
    }

    override suspend fun mediaStatus(ids: List<String>): List<MediaStatus> = backend.mediaStatus(ids)
}
