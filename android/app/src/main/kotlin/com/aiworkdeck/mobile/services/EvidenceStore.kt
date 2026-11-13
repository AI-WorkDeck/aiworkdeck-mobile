package com.aiworkdeck.mobile.services

import com.aiworkdeck.mobile.design.tr
import com.aiworkdeck.mobile.model.ArchiveMove
import com.aiworkdeck.mobile.model.ArchiveMoveReply
import com.aiworkdeck.mobile.model.ArchiveMoveStatus
import com.aiworkdeck.mobile.model.CaptureItem
import com.aiworkdeck.mobile.model.CaptureManifest
import com.aiworkdeck.mobile.model.IsoTime
import com.aiworkdeck.mobile.model.MediaKind
import com.aiworkdeck.mobile.model.RelayProject
import com.aiworkdeck.mobile.model.StoredRow
import com.aiworkdeck.mobile.model.TransferState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.security.MessageDigest
import java.time.Instant
import java.util.UUID
import java.util.logging.Logger

/** 拍摄时的定位信息，精度可能拿不到（例如室内）。 */
data class Loc(val lat: Double, val lon: Double, val accuracy: Double?)

/**
 * 影像与归档信息的本地仓库。与 iOS EvidenceStore 同一套硬规矩：
 * 落盘顺序是「先原件、再算哈希、最后写 manifest」——manifest 存在即代表这条记录完整可信，
 * 中途崩溃只会留下孤儿原件，下次启动用 sweepOrphans 扫掉。纯 JVM 实现，单测不依赖 Android。
 *
 * 所有公开挂起函数在 Dispatchers.IO 上执行，调用方无需切换（哈希与落盘都是阻塞 IO，
 * 放到主线程上会卡住取景器）。
 */
class EvidenceStore(private val root: File, private val facts: DeviceFacts) {
    private val media = File(root, "media").apply { mkdirs() }
    private val manifests = File(root, "manifest").apply { mkdirs() }
    private val mutex = Mutex()
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false; prettyPrint = true }
    private val logger = Logger.getLogger("EvidenceStore")

    suspend fun save(kind: MediaKind, temp: File, capturedAt: Instant, loc: Loc?, project: RelayProject?): CaptureItem = withContext(Dispatchers.IO) {
        mutex.withLock {
            val id = UUID.randomUUID().toString().lowercase()
            val dst = File(media, "$id.${kind.ext}")
            // 1. 原件先落盘（同目录 rename 优先；跨卷才退化到拷贝+删）
            if (kind == MediaKind.audio) temp.copyTo(dst, overwrite = true)
            else if (!temp.renameTo(dst)) { temp.copyTo(dst, overwrite = true); temp.delete() }
            // 2. 对落盘后的文件算哈希——要证明的是「磁盘上这个文件」没被改过，不是内存里的临时数据
            val sha = sha256(dst)
            val manifest = CaptureManifest(
                clientMediaId = id, sha256 = sha, capturedAt = IsoTime.format(capturedAt), serverReceivedAt = null,
                latitude = loc?.lat, longitude = loc?.lon, horizontalAccuracy = loc?.accuracy,
                deviceModel = facts.model, osVersion = facts.osVersion, appVersion = facts.appVersion,
                fromCamera = true, tsaToken = null,
            )
            val row = StoredRow(
                kind = kind, state = TransferState.waiting.raw, progress = 0.0, manifest = manifest,
                lastError = null, savedToAlbum = false, project = project, uploadAttempted = false,
            )
            // 3. manifest 最后写：存在即完整
            writeRowLocked(id, row)
            if (kind == MediaKind.audio) temp.delete()
            toItem(id, row)
        }
    }

    suspend fun loadAll(): List<CaptureItem> = withContext(Dispatchers.IO) { mutex.withLock { loadAllLocked() } }

    suspend fun updateState(id: String, to: TransferState, progress: Double = 0.0, error: String? = null, cloudResumeRequired: Boolean? = null) = withContext(Dispatchers.IO) {
        mutex.withLock {
            val row = readRowLocked(id) ?: return@withLock
            // 远端移动进行中：这件归移动事务管，上传链与暂停都不许改它
            if (row.archiveMove?.blocksMutation == true) return@withLock
            // 成功时清掉旧的失败原因，否则界面会一直挂着上次那条已经不成立的错
            val paused = cloudResumeRequired ?: row.cloudResumeRequired
            // 一旦进了「上传中」，服务端就可能已经收到——之后改项目只能走副本或远端移动
            val attempted = row.uploadAttempted ?: (row.project != null)
            val updated = row.copy(cloudResumeRequired = paused, state = if (paused) TransferState.failed.raw else to.raw, progress = if (paused) 0.0 else progress, lastError = if (paused) tr("postpaid.uploadPaused") else if (to == TransferState.failed) error else null,
                uploadAttempted = attempted || (!paused && to == TransferState.uploading))
            writeRowLocked(id, updated)
        }
    }

    /**
     * 临时项目 without persistent cloud storage: hand its captures back to the phone as unassigned
     * (no error, no failure badge) so the user can file them later. Returns how many changed.
     */
    suspend fun unassignScratch(): Int = withContext(Dispatchers.IO) {
        mutex.withLock {
            var n = 0
            for (item in loadAllLocked()) {
                if (item.moveBlocksMutation || item.project?.isScratch != true || item.state !in setOf(TransferState.waiting, TransferState.failed)) continue
                val row = readRowLocked(item.id) ?: continue
                writeRowLocked(item.id, row.copy(project = null, state = TransferState.waiting.raw, progress = 0.0, lastError = null, cloudResumeRequired = false))
                n++
            }
            n
        }
    }

    /** 旧记录上传时补记实际去向。只在 project 为空时写，不覆盖已有归属（镜像 iOS setProject）。 */
    suspend fun setProject(id: String, project: RelayProject) = withContext(Dispatchers.IO) {
        mutex.withLock {
            val row = readRowLocked(id) ?: return@withLock
            if (row.project != null || row.state != TransferState.waiting.raw) return@withLock
            writeRowLocked(id, row.copy(project = project))
        }
    }

    suspend fun markSavedToAlbum(id: String) = withContext(Dispatchers.IO) {
        mutex.withLock {
            val row = readRowLocked(id) ?: return@withLock
            writeRowLocked(id, row.copy(savedToAlbum = true))
        }
    }

    /**
     * 用户主动删除：原件与 manifest 一起删。记录留着而原件没了，图集里会出现永远打不开的空格。
     * 任一件还在远端移动中就整批不删，返回 false（镜像 iOS）。
     */
    suspend fun delete(ids: Set<String>): Boolean = withContext(Dispatchers.IO) {
        mutex.withLock {
            if (ids.any { readRowLocked(it)?.archiveMove?.blocksMutation == true }) return@withLock false
            for (id in ids) {
                media.listFiles { f -> f.nameWithoutExtension == id }?.forEach { it.delete() }
                File(manifests, "$id.json").delete()
            }
            true
        }
    }

    // MARK: - 改投项目（镜像 iOS EvidenceStore.moveToProject / copyToProject / ArchiveMove）

    /** 从没尝试过上传的件：直接改目标项目，重新排队。 */
    suspend fun moveToProject(id: String, project: RelayProject) = withContext(Dispatchers.IO) {
        mutex.withLock {
            val row = readRowLocked(id) ?: throw ApiError(1, tr("library.moveMissing"))
            if (!toItem(id, row).canMoveToProject) throw ApiError(1, tr("library.moveSynced"))
            writeRowLocked(id, row.copy(project = project, state = TransferState.waiting.raw, progress = 0.0,
                lastError = null, cloudResumeRequired = false))
        }
    }

    /** 已发出的件保留原回执；字节复制成一件独立的新传输，服务端的幂等键不会被悄悄改道。 */
    suspend fun copyToProject(id: String, project: RelayProject): CaptureItem = withContext(Dispatchers.IO) {
        mutex.withLock {
            val row = readRowLocked(id) ?: throw ApiError(1, tr("library.moveMissing"))
            val item = toItem(id, row)
            if (item.moveBlocksMutation) throw ApiError(1, tr("queue.moveInProgress"))
            if (!item.localFile.exists()) throw ApiError(1, tr("queue.copyMissing"))
            val copyId = UUID.randomUUID().toString().lowercase()
            val dst = File(media, "$copyId.${row.kind.ext}")
            var saved = false
            try {
                item.localFile.copyTo(dst, overwrite = true)
                if (sha256(dst) != row.manifest.sha256) throw ApiError(1, tr("queue.copyCorrupt"))
                val copy = StoredRow(kind = row.kind, state = TransferState.waiting.raw, progress = 0.0,
                    manifest = row.manifest.copy(clientMediaId = copyId, serverReceivedAt = null),
                    lastError = null, savedToAlbum = false, project = project, uploadAttempted = false)
                writeRowLocked(copyId, copy)
                saved = true
                toItem(copyId, copy)
            } finally {
                if (!saved) dst.delete()
            }
        }
    }

    suspend fun beginArchiveMove(id: String, target: RelayProject, accountBinding: String,
                                 accountIsCurrent: () -> Boolean = { true }): ArchiveMove = withContext(Dispatchers.IO) {
        mutex.withLock {
            if (!accountIsCurrent()) throw ApiError(1, tr("queue.moveAccountChanged"))
            val row = readRowLocked(id) ?: throw ApiError(1, tr("library.moveMissing"))
            val item = toItem(id, row)
            if (item.moveBlocksMutation) throw ApiError(1, tr("queue.moveInProgress"))
            val source = item.project
            if (!item.canRequestArchiveMove || source == null) throw ApiError(1, tr("queue.moveUnavailable"))
            if (source.matches(target)) throw ApiError(1, tr("queue.moveSameProject"))
            if (row.accountBinding != null && row.accountBinding != accountBinding) throw ApiError(1, tr("queue.moveAccountChanged"))
            if (!item.localFile.exists()) throw ApiError(1, tr("queue.copyMissing"))
            if (sha256(item.localFile) != row.manifest.sha256) throw ApiError(1, tr("queue.copyCorrupt"))
            val move = ArchiveMove(
                requestId = UUID.randomUUID().toString().lowercase(),
                sourceClientMediaId = item.effectiveClientMediaId,
                targetClientMediaId = UUID.randomUUID().toString().lowercase(),
                source = source, target = target, sha256 = row.manifest.sha256,
                fileSize = item.localFile.length(), accountBinding = accountBinding,
            )
            writeRowLocked(id, row.copy(archiveMove = move))
            move
        }
    }

    suspend fun archiveMoveItem(id: String): CaptureItem? = withContext(Dispatchers.IO) {
        mutex.withLock { readRowLocked(id)?.let { toItem(id, it) } }
    }

    suspend fun applyArchiveMoveReply(id: String, requestId: String, reply: ArchiveMoveReply,
                                      accountIsCurrent: () -> Boolean = { true }) = withContext(Dispatchers.IO) {
        mutex.withLock {
            if (!accountIsCurrent()) return@withLock
            val row = readRowLocked(id) ?: return@withLock
            val move = row.archiveMove ?: return@withLock
            if (move.requestId != requestId) return@withLock
            if (!reply.requestId.equals(move.requestId, ignoreCase = true) ||
                !reply.targetClientMediaId.equals(move.targetClientMediaId, ignoreCase = true)) {
                throw ApiError(1, tr("error.badResponse"))
            }
            // 迟到的轮询回复不能撤销已完成的事务
            if (move.status == ArchiveMoveStatus.done) return@withLock
            // 手动重试后，中转过期可能要求把同一份目标再传一次
            val reupload = move.retryRequested && reply.status == ArchiveMoveStatus.waitingTarget
            val next = move.copy(
                registered = true, registrationRejected = false, status = reply.status,
                lastError = reply.error?.takeIf { it.isNotBlank() }, retryRequested = false,
                targetUploaded = when {
                    reply.status == ArchiveMoveStatus.waitingSource || reply.status == ArchiveMoveStatus.done -> true
                    reupload -> false
                    else -> move.targetUploaded
                },
            )
            val updated = if (reply.status == ArchiveMoveStatus.done) row.copy(
                archiveMove = next, project = next.target, remoteClientMediaId = next.targetClientMediaId,
                state = TransferState.arrived.raw, progress = 1.0, lastError = null,
                // 新回执归属当前账号：之后的移动只能由同一账号发起
                accountBinding = next.accountBinding,
            ) else row.copy(archiveMove = next)
            writeRowLocked(id, updated)
        }
    }

    suspend fun updateArchiveMove(id: String, requestId: String, accountIsCurrent: () -> Boolean = { true },
                                  change: (ArchiveMove) -> ArchiveMove) = withContext(Dispatchers.IO) {
        mutex.withLock {
            if (!accountIsCurrent()) return@withLock
            val row = readRowLocked(id) ?: return@withLock
            val move = row.archiveMove ?: return@withLock
            if (move.requestId != requestId || move.status == ArchiveMoveStatus.done) return@withLock
            writeRowLocked(id, row.copy(archiveMove = change(move)))
        }
    }

    /**
     * 清理孤儿原件：有文件没 manifest，说明上次写到一半崩了；没有哈希与采集环境，留着只会误导。
     *
     * 保留名单按磁盘上的 manifest **文件名**算，而不是 loadAll 解析出来的记录：解析不了的
     * manifest（写坏了、字段对不上）会被 loadAll 跳过，照那份名单扫就等于把还有 manifest 的
     * 原件也删了——现场不可复现，宁可留着一份待人工捞的原件。
     */
    suspend fun sweepOrphans(): Int = withContext(Dispatchers.IO) {
        mutex.withLock {
            val known = manifests.listFiles { f -> f.extension == "json" }.orEmpty()
                .map { it.nameWithoutExtension }.toSet()
            var removed = 0
            for (f in media.listFiles().orEmpty()) {
                if (f.nameWithoutExtension !in known) { f.delete(); removed++ }
            }
            removed
        }
    }

    private fun loadAllLocked(): List<CaptureItem> {
        val files = manifests.listFiles { f -> f.extension == "json" }.orEmpty()
        val items = files.mapNotNull { f ->
            try {
                val row = json.decodeFromString<StoredRow>(f.readText())
                toItem(row.manifest.clientMediaId, row)
            } catch (e: Exception) {
                logger.warning("跳过无法解析的 manifest ${f.name}: ${e.message}")
                null
            }
        }
        return items.sortedByDescending { it.capturedAt }
    }

    private fun readRowLocked(id: String): StoredRow? = try {
        val f = File(manifests, "$id.json")
        if (f.exists()) json.decodeFromString<StoredRow>(f.readText()) else null
    } catch (e: Exception) {
        logger.warning("读取 manifest 出错 $id: ${e.message}")
        null
    }

    private fun writeRowLocked(id: String, row: StoredRow) {
        val target = File(manifests, "$id.json")
        val tmp = File(manifests, "$id.json.tmp")
        tmp.writeText(json.encodeToString(row))
        if (!tmp.renameTo(target)) { tmp.copyTo(target, overwrite = true); tmp.delete() }
    }

    /** 解不出的 state（既非正式名也非别名）视为 failed，并把原始值记进 lastError 方便排查。 */
    private fun toItem(id: String, row: StoredRow): CaptureItem {
        val state = TransferState.fromRaw(row.state)
        return CaptureItem(
            id = id, kind = row.kind, state = state ?: TransferState.failed, manifest = row.manifest,
            localFile = File(media, "$id.${row.kind.ext}"), progress = row.progress,
            lastError = if (state == null) tr("queue.unknownState", mapOf("state" to row.state)) else row.lastError,
            savedToAlbum = row.savedToAlbum ?: false, project = row.project, cloudResumeRequired = row.cloudResumeRequired,
            uploadAttempted = row.uploadAttempted ?: (row.project != null), archiveMove = row.archiveMove,
            remoteClientMediaId = row.remoteClientMediaId, accountBinding = row.accountBinding,
        )
    }

    /** 流式分块算哈希：现场录像可以到几百 MB，整份读进内存不划算。 */
    fun sha256(f: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        f.inputStream().use { i ->
            val b = ByteArray(1 shl 20)
            while (true) { val n = i.read(b); if (n < 0) break; md.update(b, 0, n) }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }
}
