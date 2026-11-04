package com.aiworkdeck.mobile.services

import com.aiworkdeck.mobile.design.tr
import com.aiworkdeck.mobile.model.TransferState
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.time.Instant

class CloudWriteGeneration(val value: Long) : kotlin.coroutines.AbstractCoroutineContextElement(Key) {
    companion object Key : kotlin.coroutines.CoroutineContext.Key<CloudWriteGeneration>
}

/** Disk binding survives app restart and session rotation; only explicit reconnect can replace it. */
object CloudEpoch {
    private val snapshots = mutableMapOf<String, String>()
    private var root: File? = null
    private var store: EvidenceStore? = null
    private var started = Instant.now()
    private var generation = 0L
    @Synchronized fun configure(directory: File, evidence: EvidenceStore, launch: Instant = Instant.now()) {
        root = directory.apply { mkdirs() }; store = evidence; started = launch; invalidate()
    }
    @Synchronized fun revision(): Long = generation
    fun accountChanged() { invalidate(); pause() }
    @Synchronized fun invalidate() { generation++; snapshots.clear() }
    private fun pause() = runBlocking {
        store?.loadAll()?.filter { it.state in setOf(TransferState.waiting, TransferState.uploading, TransferState.failed) }?.forEach {
            store?.updateState(it.id, TransferState.failed, cloudResumeRequired = true)
        }
    }
    fun reconnect(request: Request, client: OkHttpClient) { invalidate(); pause(); authorize(request, client, true) }
    fun authorize(request: Request, client: OkHttpClient, explicit: Boolean = false, expectedGeneration: Long? = null): Request {
        val token = request.header("X-Session-Id") ?: return request
        val url = request.url
        if (url.scheme != "https" || url.host !in setOf("addin.aiworkdeck.com", "addin.workdeck.ai") || request.method == "GET" ||
            Regex("^/api/(auth|account|feedback|mobile/billing)(/|$)").containsMatchIn(url.encodedPath)) return request
        val origin = "${url.scheme}://${url.host}:${url.port}"
        val key = "$origin\n$token"
        val revision: Long
        var epoch: String?
        synchronized(this) { revision = expectedGeneration ?: generation; if (revision != generation) throw ApiError(1, tr("postpaid.refresh")); epoch = snapshots[key] }
        if (epoch == null || explicit) {
            fun probe(path: String): Pair<Int, JsonObject?> = client.newCall(request.newBuilder().url(origin + path).get().build()).execute().use {
                it.code to runCatching { Json.parseToJsonElement(it.body?.string() ?: "").jsonObject }.getOrNull()
            }
            val (identityCode, identity) = probe("/api/auth/me")
            val userId = identity?.get("data")?.jsonObject?.get("id")?.jsonPrimitive?.longOrNull
            if (identityCode != 200 || identity?.get("code")?.jsonPrimitive?.intOrNull != 0 || userId == null || userId <= 0) throw ApiError(1, tr("error.unauthorized"))
            val scope = "$origin:$userId"
            val hash = java.security.MessageDigest.getInstance("SHA-256").digest(scope.toByteArray()).joinToString("") { "%02x".format(it) }
            val directory = synchronized(this) { root } ?: throw ApiError(1, tr("postpaid.refresh"))
            val file = File(directory, hash)
            val (code, state) = probe("/api/mobile/billing/cloud-state")
            val value = state?.get("cloudAccess")?.jsonObject?.get("epoch")?.jsonPrimitive?.longOrNull
            epoch = if (code == 404) "legacy" else if (code == 200 && value != null && value >= 0) value.toString() else throw ApiError(1, tr("postpaid.refresh"))
            val legacyQueue = runBlocking { store?.loadAll()?.any { it.state in setOf(TransferState.waiting,TransferState.uploading,TransferState.failed) && it.capturedAt < started } == true }
            val denied = synchronized(this) {
                if (revision != generation) throw ApiError(1, tr("postpaid.refresh"))
                val old = if (file.exists()) file.readText() else null
                if (!explicit && ((old != null && old != epoch) || (old == null && legacyQueue))) true
                else {
                    val temporary = File(directory, "$hash.tmp")
                    temporary.writeText(requireNotNull(epoch))
                    check(temporary.renameTo(file))
                    snapshots[key] = requireNotNull(epoch)
                    false
                }
            }
            if (denied) { pause(); throw ApiError(1, tr("postpaid.refresh")) }

        }
        synchronized(this) { if (revision != generation) throw ApiError(1, tr("postpaid.refresh")) }
        return if (epoch != "legacy") request.newBuilder().header("X-Cloud-Epoch", requireNotNull(epoch)).build() else request
    }
}
