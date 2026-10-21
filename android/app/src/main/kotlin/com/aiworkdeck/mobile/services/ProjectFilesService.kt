package com.aiworkdeck.mobile.services

import com.aiworkdeck.contract.ContractCapabilities
import com.aiworkdeck.mobile.design.tr
import com.aiworkdeck.mobile.model.RelayProject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import kotlin.coroutines.coroutineContext

@Serializable
data class BackupConsent(val enabled: Boolean, val decided: Boolean, val subscriptionActive: Boolean, val consentVersion: String? = null)
@Serializable
data class ProjectFile(val id: String, val name: String, val path: String = "", val size: Long,
    val uid: String? = null, val source: String? = null, val deviceId: String? = null,
    val projectKey: String? = null, val isFolder: Boolean = false) {
    val rowID: String get() = uid ?: "$source:$deviceId:$projectKey:$id"
    val extension: String get() = name.substringAfterLast('.', "").lowercase()
}
@Serializable
data class ProjectFileListing(val files: List<ProjectFile>, val truncated: Boolean = files.size >= 2000)
data class FileEntry(val key: String, val name: String, val path: String, val file: ProjectFile? = null)
fun folderEntries(files: List<ProjectFile>, folder: String = ""): List<FileEntry> {
    val prefix = if (folder.isEmpty()) "" else "$folder/"
    val entries = linkedMapOf<String, FileEntry>()
    for (file in files) {
        val path = (file.path.ifEmpty { file.name }).replace('\\', '/').split('/').filter { it.isNotEmpty() && it != "." && it != ".." }.joinToString("/")
        if (!path.startsWith(prefix) || path == folder) continue
        val parts = path.removePrefix(prefix).split('/')
        val entry = if (parts.size > 1 || file.isFolder) FileEntry("folder:" + prefix + parts[0], parts[0], prefix + parts[0])
            else FileEntry(file.rowID, file.name, path, file)
        entries[entry.key] = entry
    }
    return entries.values.sortedWith(compareBy<FileEntry> { it.file != null }.thenBy { it.name.lowercase() })
}
fun validatePreview(file: ProjectFile) {
    if (file.isFolder || file.extension !in ContractCapabilities.previewExtensions) throw IllegalArgumentException(tr("files.unsupported"))
    if (file.size < 0 || file.size > ProjectFilesService.MAX_BYTES) throw IllegalArgumentException(tr("files.error.tooLarge"))
}

/** One immutable account snapshot; charged requests are durable before sending and reused on retry. */
class ProjectFilesService(private val baseURL: String, private val session: String, private val language: String,
    root: File, client: OkHttpClient, private val active: () -> Boolean) {
    private val client = client.newBuilder().followRedirects(false).followSslRedirects(false).build()
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }
    private val root = File(root, fingerprint(baseURL + "\n" + session)).apply { mkdirs() }
    @Volatile private var closed = false
    private val cloudFiles = java.util.Collections.synchronizedList(mutableListOf<File>())
    private class TerminalTransfer : Exception(tr("files.error.transferFailed"))
    @Serializable private data class Pending(val requestId: String, val project: RelayProject, val file: ProjectFile, val transferId: Long? = null,
        val filename: String? = null, val size: Long? = null, val acknowledged: Boolean = false)
    init {
        val retained = mutableSetOf<String>()
        var unreadable = false
        for (manifest in this.root.listFiles { f -> f.extension == "json" }.orEmpty()) {
            val pending = runCatching { read(manifest) }.getOrNull()
            if (pending == null) { unreadable = true; continue }
            if (pending.acknowledged) manifest.delete() else pending.filename?.let { retained.add(it) }
        }
        if (!unreadable) this.root.listFiles { f -> f.extension != "json" && f.name !in retained }.orEmpty().forEach { it.delete() }
    }
    private fun ensureOpen() { check(!closed && active()) { tr("files.error.closed") } }
    private fun ledger(project: RelayProject, file: ProjectFile) = File(root, fingerprint(project.id + ":" + file.rowID) + ".json")
    private fun read(file: File): Pending? = if (file.exists()) json.decodeFromString<Pending>(file.readText()) else null
    private fun save(file: File, pending: Pending) {
        ensureOpen()
        val temp = File(file.path + ".tmp"); temp.writeText(json.encodeToString(pending))
        check(temp.renameTo(file)) { tr("files.error.response") }
    }
    fun hasPending(project: RelayProject, file: ProjectFile): Boolean = read(ledger(project, file)) != null
    suspend fun files(project: RelayProject): ProjectFileListing {
        ensureOpen()
        val desktop = project.locations.orEmpty().firstOrNull { it.kind == "desktop" && it.online == true }
            ?: if (project.locations == null && project.deviceId != "cloud" && !project.deviceId.startsWith("cloud:")) com.aiworkdeck.mobile.model.ProjectLocation("desktop", project.deviceId, project.key, online = true) else null
        val catalog = project.projectUid?.let { uid -> try {
            json.decodeFromJsonElement<ProjectFileListing>(request("/api/mobile/catalog/${segment(uid)}/files"))
        } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (_: Exception) { null } }
        ensureOpen(); coroutineContext.ensureActive()
        if (desktop == null) return catalog ?: throw IllegalStateException(tr("files.desktopRequired"))
        return try {
            val created = request("/api/mobile/transfer/list", buildJsonObject {
                put("deviceId", desktop.deviceId); put("projectKey", desktop.key); put("requestId", UUID.randomUUID().toString())
            })
            val transfer = poll(created.getValue("id").jsonPrimitive.long, "LIST", "DONE")
            val live = json.decodeFromJsonElement<List<ProjectFile>>(transfer.getValue("files")).map {
                it.copy(source = "desktop", deviceId = desktop.deviceId, projectKey = desktop.key)
            }
            val merged = catalog?.files.orEmpty().filterNot { old -> live.any { fresh ->
                (old.uid != null && fresh.uid == old.uid) || (old.id == fresh.id && old.deviceId == fresh.deviceId && old.projectKey == fresh.projectKey)
            } } + live
            ProjectFileListing(merged, catalog == null || catalog.truncated || (transfer["truncated"]?.jsonPrimitive?.booleanOrNull ?: (live.size >= 2000)))
        } catch (e: kotlinx.coroutines.CancellationException) { throw e }
        catch (e: Exception) { catalog ?: throw e }
    }
    suspend fun quote(file: ProjectFile): Int {
        validatePreview(file)
        return request("/api/mobile/transfer/quote?bytes=${file.size.coerceAtLeast(1)}").getValue("credits").jsonPrimitive.int
    }
    suspend fun download(project: RelayProject, file: ProjectFile): File {
        validatePreview(file); ensureOpen()
        val manifest = ledger(project, file)
        val existing = read(manifest)
        if (existing == null && isCloudFile(project, file)) {
            val consent = json.decodeFromJsonElement<BackupConsent>(request("/api/mobile/backup-consent"))
            check(consent.enabled && consent.subscriptionActive) { tr("files.desktopRequired") }
            val uid = project.projectUid ?: error(tr("files.error.response"))
            val fid = file.uid ?: error(tr("files.error.response"))
            return content("/api/mobile/preview/catalog/${segment(uid)}/files/${segment(fid)}/content", file.size, file.extension).also { cloudFiles.add(it) }
        }
        var pending = existing ?: Pending(UUID.randomUUID().toString(), project, file).also { save(manifest, it) }
        val original = pending.file
        val target = pending.project
        validatePreview(original)
        if (pending.transferId == null) {
            val created = request("/api/mobile/preview/pull", buildJsonObject {
                put("deviceId", original.deviceId ?: target.deviceId); put("projectKey", original.projectKey ?: target.key)
                put("remoteFileId", original.id); put("fileName", original.name); put("fileSize", original.size); put("requestId", pending.requestId)
            })
            pending = pending.copy(transferId = created.getValue("id").jsonPrimitive.long); save(manifest, pending)
        }
        if (pending.filename == null) {
            val transfer = try { poll(pending.transferId!!, "PULL", "STAGED") } catch (e: TerminalTransfer) { manifest.delete(); throw e }
            val size = transfer["fileSize"]?.jsonPrimitive?.longOrNull ?: error(tr("files.error.response"))
            validatePreview(original.copy(size = size))
            val local = content("/api/mobile/transfer/${pending.transferId}/content", size, original.extension)
            pending = pending.copy(filename = local.name, size = size); save(manifest, pending)
        }
        val filename = pending.filename!!
        check(File(filename).name == filename) { tr("files.error.response") }
        val local = File(root, filename)
        check(local.isFile && local.length() == pending.size) { tr("files.error.response") }
        if (!pending.acknowledged) {
            request("/api/mobile/transfer/${pending.transferId}/ack", buildJsonObject {})
            pending = pending.copy(acknowledged = true); save(manifest, pending)
        }
        ensureOpen(); return local
    }
    private suspend fun poll(id: Long, kind: String, status: String): JsonObject {
        repeat(60) {
            val transfer = request("/api/mobile/transfer/$id").getValue("transfer").jsonObject
            check(transfer["id"]?.jsonPrimitive?.longOrNull == id && transfer["kind"]?.jsonPrimitive?.content == kind) { tr("files.error.response") }
            val actual = transfer["status"]?.jsonPrimitive?.content
            if (actual == status) return transfer
            if (actual == "FAILED" || actual == "EXPIRED" || actual == "CANCELLED") throw TerminalTransfer()
            check(actual == "PENDING") { tr("files.error.transferFailed") }
            delay(1000)
        }
        error(tr("files.error.timeout"))
    }
    private fun builder(path: String) = Request.Builder().url(baseURL + path)
        .header("X-Session-Id", session).header("X-App-Language", language)
    private suspend fun request(path: String, body: JsonObject? = null): JsonObject = withContext(Dispatchers.IO) {
        ensureOpen(); coroutineContext.ensureActive()
        val builder = builder(path)
        if (body != null) builder.post(body.toString().toRequestBody("application/json".toMediaType()))
        client.newCall(builder.build()).execute().use { response ->
            ensureOpen(); coroutineContext.ensureActive()
            check(response.isSuccessful) { tr("files.error.response") }
            val value = json.parseToJsonElement(response.body?.string() ?: "").jsonObject
            val code = value["code"]?.jsonPrimitive?.intOrNull
            check(code == null || code == 0) { value["message"]?.jsonPrimitive?.contentOrNull ?: tr("files.error.response") }
            value
        }
    }
    private suspend fun content(path: String, expected: Long, extension: String): File = withContext(Dispatchers.IO) {
        ensureOpen(); coroutineContext.ensureActive()
        check(expected in 0..MAX_BYTES) { tr("files.error.tooLarge") }
        check(root.listFiles().orEmpty().filter { it.extension != "json" }.sumOf { it.length() } + expected <= MAX_BYTES) { tr("files.error.cacheFull") }
        val destination = File(root, UUID.randomUUID().toString() + "." + extension)
        try {
            client.newCall(builder(path).build()).execute().use { response ->
                val body = response.body ?: error(tr("files.error.response"))
                check(response.isSuccessful && body.contentType()?.let { it.type == "application" && it.subtype == "octet-stream" } == true && body.contentLength() == expected) { tr("files.error.response") }
                body.byteStream().use { input -> destination.outputStream().use { output ->
                    val buffer = ByteArray(65536); var total = 0L
                    while (true) {
                        ensureOpen(); coroutineContext.ensureActive()
                        val n = input.read(buffer); if (n < 0) break
                        total += n; check(total <= expected) { tr("files.error.response") }; output.write(buffer, 0, n)
                    }
                    check(total == expected) { tr("files.error.response") }
                } }
            }
            ensureOpen(); destination
        } catch (e: Exception) { destination.delete(); throw e }
    }
    fun close() {
        closed = true
        for (manifest in root.listFiles { f -> f.extension == "json" }.orEmpty()) {
            val pending = runCatching { read(manifest) }.getOrNull() ?: continue
            if (pending.acknowledged) {
                pending.filename?.takeIf { File(it).name == it }?.let { File(root, it).delete() }
                manifest.delete()
            }
        }
        synchronized(cloudFiles) { cloudFiles.forEach { it.delete() }; cloudFiles.clear() }
    }
    companion object {
        const val MAX_BYTES = 200L * 1024 * 1024
        private fun fingerprint(value: String) = MessageDigest.getInstance("SHA-256").digest(value.toByteArray()).joinToString("") { "%02x".format(it) }
        private fun segment(value: String) = java.net.URLEncoder.encode(value, "UTF-8").replace("+", "%20")
    }
}

fun isCloudFile(project: RelayProject, file: ProjectFile): Boolean = file.source == "cloud" || file.source == "backup" ||
    (file.source == null && (project.deviceId == "cloud" || project.deviceId.startsWith("cloud:") || project.locations.orEmpty().any { it.kind == "cloud" && it.deviceId == project.deviceId && it.key == project.key }))
