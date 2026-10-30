package com.aiworkdeck.mobile.services

import com.aiworkdeck.mobile.model.CaptureItem
import com.aiworkdeck.mobile.model.RelayProject

/** UploadQueue 依赖的最小上传契约，方便单测用 FakeUploader 顶替 Backend。 */
interface Uploader {
    suspend fun upload(item: CaptureItem, project: RelayProject, fileName: String, onProgress: (Double) -> Unit): UploadResult
    suspend fun mediaStatus(ids: List<String>): List<MediaStatus>
}

/**
 * Backend 的瘦适配层：把 CaptureItem + RelayProject + 已算好的文件名，拼成 Backend.upload
 * 要的六个字段。deviceId 现取现拿（不缓存），跟 iOS 一样不假设设备身份在队列生命周期内不变。
 */
class BackendUploader(private val backend: Backend, private val organizationPrefs: Prefs? = null, private val deviceIdProvider: () -> String) : Uploader {
    override suspend fun upload(item: CaptureItem, project: RelayProject, fileName: String, onProgress: (Double) -> Unit): UploadResult {
        val active = backend.accountSnapshot()
        val scope = active.personalAccountScope()
        val organize = organizationPrefs?.organizeCaptures(scope) == true
        val result = active.upload(
            file = item.localFile,
            deviceId = deviceIdProvider(),
            projectKey = project.key,
            clientMediaId = item.manifest.clientMediaId,
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
                        prefs.saveOrganization(scope, item.manifest.clientMediaId, result.organization ?: CaptureOrganization("unknown"))
                }
            }
        }
        return result
    }

    override suspend fun mediaStatus(ids: List<String>): List<MediaStatus> = backend.mediaStatus(ids)
}
