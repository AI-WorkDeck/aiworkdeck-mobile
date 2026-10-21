package com.aiworkdeck.mobile.services

import com.aiworkdeck.mobile.design.tr
import com.aiworkdeck.mobile.model.MediaKind
import com.aiworkdeck.mobile.model.RelayProject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.time.Instant
import java.util.UUID

/** Metadata is durable before recording starts; process death leaves originals available for recovery. */
class RecordingDrafts(private val root: File) {
    @Serializable data class Draft(val name: String, val startedAt: Long, val project: RelayProject?,
        val lat: Double? = null, val lon: Double? = null, val accuracy: Double? = null) {
        val location: Loc? get() = if (lat != null && lon != null) Loc(lat, lon, accuracy) else null
    }
    private val json = Json { ignoreUnknownKeys = true }
    fun create(at: Long, request: RecordingState.StartRequest?): Draft {
        root.mkdirs()
        val draft = Draft(UUID.randomUUID().toString() + ".m4a", at, request?.project, request?.loc?.lat, request?.loc?.lon, request?.loc?.accuracy)
        File(root, draft.name + ".json").writeText(json.encodeToString(draft))
        return draft
    }
    fun file(draft: Draft): File = File(root, draft.name)
    fun complete(draft: Draft) { File(root, draft.name + ".json").delete() }
    // A restart may follow a different sign-in; recovered audio requires explicit reassignment.
    suspend fun recover(store: EvidenceStore): String? = withContext(Dispatchers.IO) {
        var recovered = 0; var invalid = 0; var failed = 0
        for (metadata in root.listFiles { f -> f.extension == "json" }.orEmpty()) {
            val draft = runCatching { json.decodeFromString<Draft>(metadata.readText()) }.getOrNull() ?: continue
            if (File(draft.name).name != draft.name) continue
            val source = file(draft)
            if (!source.exists()) { complete(draft); continue }
            if (!isPlayableAudio(source)) { invalid++; continue }
            try { store.save(MediaKind.audio, source, Instant.ofEpochMilli(draft.startedAt), draft.location, null); complete(draft); recovered++ }
            catch (_: Exception) { failed++ }
        }
        buildList {
            if (recovered > 0) add(tr("rec.recovery.saved", mapOf("count" to recovered)))
            if (invalid > 0) add(tr("rec.recovery.noAudio", mapOf("count" to invalid)))
            if (failed > 0) add(tr("rec.recovery.saveFailed", mapOf("count" to failed)))
        }.takeIf { it.isNotEmpty() }?.joinToString("\n")
    }
}
