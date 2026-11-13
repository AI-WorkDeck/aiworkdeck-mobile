package com.aiworkdeck.mobile.model

import kotlinx.serialization.Serializable
import java.io.File
import java.time.Instant
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter

enum class MediaKind { photo, video, audio;
    val ext: String get() = when (this) { photo -> "jpg"; video -> "mp4"; audio -> "m4a" }
    val mediaType: String get() = when (this) { photo -> "image"; video -> "video"; audio -> "audio" }
}

/** 取证归档信息，字段与 iOS CaptureManifest.swift 一致。日期为 ISO8601 字符串。 */
@Serializable
data class CaptureManifest(
    val clientMediaId: String, val sha256: String, val capturedAt: String, val serverReceivedAt: String? = null,
    val latitude: Double? = null, val longitude: Double? = null, val horizontalAccuracy: Double? = null,
    val deviceModel: String, val osVersion: String, val appVersion: String, val fromCamera: Boolean, val tsaToken: String? = null,
)

@Serializable
data class RelayProject(val deviceId: String, val deviceName: String? = null, val key: String, val name: String,
                        val projectUid: String? = null, val locations: List<ProjectLocation>? = null, val isDefault: Boolean = false, val projectType: String? = null) {
    val id: String get() = projectUid ?: "$deviceId:$key"
    /** The account's cloud scratch project (临时项目): cloud-only, billed as persistent storage. */
    val isScratch: Boolean get() = isDefault || projectType == "SCRATCH"
    fun matches(other: RelayProject): Boolean {
        if (projectUid != null && other.projectUid != null) return projectUid == other.projectUid
        val aliases = (locations.orEmpty().map { "${it.deviceId}:${it.key}" } + "$deviceId:$key").toSet()
        return (other.locations.orEmpty().map { "${it.deviceId}:${it.key}" } + "${other.deviceId}:${other.key}").any { it in aliases }
    }
}

@Serializable
data class ProjectLocation(val kind: String, val deviceId: String, val key: String,
                           val deviceName: String? = null, val online: Boolean? = null, val archiveOnly: Boolean? = null, val projectUid: String? = null, val projectType: String? = null, val owned: Boolean? = null)

@Serializable
data class CatalogProject(val projectUid: String, val name: String, val locations: List<ProjectLocation>, val isDefault: Boolean = false, val projectType: String? = null) {
    fun toRelayProject(): RelayProject {
        val source = locations.firstOrNull { it.kind == "cloud" && it.archiveOnly != true }
            ?: locations.firstOrNull { it.kind == "desktop" && it.online == true }
            ?: locations.firstOrNull { it.kind == "desktop" } ?: locations.first()
        return RelayProject(source.deviceId, source.deviceName, source.key, name, projectUid, locations, isDefault, projectType)
    }
}

/** 落盘行，与 iOS StoredRow 同形。state 存正式名字符串。 */
@Serializable
data class StoredRow(
    val kind: MediaKind, val state: String, val progress: Double, val manifest: CaptureManifest,
    val cloudResumeRequired: Boolean = false, val lastError: String? = null, val savedToAlbum: Boolean? = null, val project: RelayProject? = null,
    /** 旧记录没有这一项：按 iOS 规则「有项目即视为已尝试过上传」。 */
    val uploadAttempted: Boolean? = null, val archiveMove: ArchiveMove? = null, val remoteClientMediaId: String? = null,
    /** 移动完成后，新的远端回执归属的账号绑定（iOS watchAccountBinding 的对应）。 */
    val accountBinding: String? = null,
)

data class CaptureItem(
    val id: String, val kind: MediaKind, val state: TransferState, val manifest: CaptureManifest, val localFile: File,
    val progress: Double, val lastError: String?, val savedToAlbum: Boolean, val project: RelayProject?, val cloudResumeRequired: Boolean = false,
    /** 一旦尝试过上传，服务端可能已收到；之后改项目只能走独立副本或远端移动，不能悄悄改幂等键的去向。 */
    val uploadAttempted: Boolean = false,
    val archiveMove: ArchiveMove? = null,
    val remoteClientMediaId: String? = null,
    val accountBinding: String? = null,
) {
    val capturedAt: Instant get() = IsoTime.parse(manifest.capturedAt) ?: Instant.EPOCH
    /** 远端认的那个 clientMediaId：移动完成后换成目标回执，本机证据身份（[id]）不变。 */
    val effectiveClientMediaId: String get() = remoteClientMediaId ?: manifest.clientMediaId
    val moveBlocksMutation: Boolean get() = archiveMove?.blocksMutation == true
    val canMoveToProject: Boolean get() = !moveBlocksMutation && !uploadAttempted && (state == TransferState.waiting || state == TransferState.failed)
    val canRequestArchiveMove: Boolean get() = !moveBlocksMutation && project != null && uploadAttempted && state != TransferState.uploading
    /** 队列里显示的状态：移动未完成时，等待算「上传中」、失败算「失败」。 */
    val queueState: TransferState get() {
        val move = archiveMove ?: return state
        if (move.status == ArchiveMoveStatus.done) return state
        return if (move.status == ArchiveMoveStatus.failed) TransferState.failed else TransferState.uploading
    }
    val queueCaption: String get() = archiveMove?.takeIf { it.status != ArchiveMoveStatus.done }?.status?.caption ?: state.caption
    val queueError: String? get() {
        val move = archiveMove
        return if (move != null && move.status != ArchiveMoveStatus.done) move.lastError else lastError
    }
}

object IsoTime {
    private val out = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ssXXX")
    fun format(instant: Instant, zone: ZoneId = ZoneId.systemDefault()): String = out.format(instant.atZone(zone))

    /** 宽容解析：带偏移（含 Z、含小数秒）走 OffsetDateTime；无偏移按本地时区补齐。 */
    fun parse(s: String, zone: ZoneId = ZoneId.systemDefault()): Instant? = try {
        runCatching { OffsetDateTime.parse(s).toInstant() }
            .getOrElse { LocalDateTime.parse(s).atZone(zone).toInstant() }
    } catch (_: Exception) { null }
}
