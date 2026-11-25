// SPDX-FileCopyrightText: 2026 北京公富信息技术有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
package com.aiworkdeck.mobile.services.firm

import com.aiworkdeck.mobile.design.L10n
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive

// Firm review (docs/specs/2026-11-19-firm-review.md), ported 1:1 from ios/Sources/Services/FirmPortal.swift.
// Wire models are lenient: the portal adds fields over time.

/** JSON for portal replies: unknown fields ignored, missing fields null. */
val FirmJson = Json { ignoreUnknownKeys = true; explicitNulls = false; coerceInputValues = true }

/** Text in several languages from the portal (`en`, `zh`, optionally `zht`, `ja`, `ms`, ...). Null and empty values are dropped. */
@Serializable(with = FirmName.Serializer::class)
data class FirmName(val values: Map<String, String>) {
    constructor(en: String? = null, zh: String? = null) : this(listOfNotNull(en?.let { "en" to it }, zh?.let { "zh" to it }).toMap())

    val en: String? get() = values["en"]
    val zh: String? get() = values["zh"]

    /** The app language when present, else English, else Chinese, else anything. */
    fun text(locale: String): String {
        val keys = when {
            locale == "zh-Hant" -> listOf("zht", "zh")
            locale.startsWith("zh") -> listOf("zh")
            else -> listOf(locale, locale.take(2))
        }
        for (k in keys + listOf("en", "zh")) values[k]?.let { return it }
        return values.toSortedMap().values.firstOrNull() ?: ""
    }
    val text: String get() = text(L10n.locale)

    object Serializer : KSerializer<FirmName> {
        override val descriptor: SerialDescriptor = JsonObject.serializer().descriptor
        override fun deserialize(decoder: Decoder): FirmName {
            val obj = (decoder as JsonDecoder).decodeJsonElement() as? JsonObject ?: return FirmName(emptyMap())
            return FirmName(obj.mapNotNull { (k, v) ->
                if (v is JsonNull || v !is JsonPrimitive) null else v.jsonPrimitive.contentOrNull?.takeIf { it.isNotEmpty() }?.let { k to it }
            }.toMap())
        }
        override fun serialize(encoder: Encoder, value: FirmName) {
            encoder.encodeSerializableValue(JsonObject.serializer(), JsonObject(value.values.mapValues { JsonPrimitive(it.value) }))
        }
    }
}

private fun displayName(names: FirmName?, english: String?): String? =
    names?.text?.takeIf { it.isNotEmpty() } ?: english?.takeIf { it.isNotEmpty() }

@Serializable
data class FirmMe(
    val kind: String,
    val name: String? = null,
    val status: String? = null,
    val lawyerId: String? = null,
    val trialUntil: String? = null,
    val firm: FirmName? = null,
    /** The firm's catalog name for this lawyer, set when the firm approves the account. */
    val lawyerName: FirmName? = null,
    val lawyerTitle: FirmName? = null,
    val lawyerOffice: FirmName? = null,
    /** "demo" when the account sees demo matters only. */
    val scope: String? = null,
)

@Serializable
data class FirmConsult(
    val status: String? = null,
    val times: String? = null,
    val note: String? = null,
    val lawyerName: String? = null,
    val lawyerNames: FirmName? = null,
) { val lawyerDisplayName: String? get() = displayName(lawyerNames, lawyerName) }

@Serializable
data class FirmMatterSummary(
    val id: String,
    val status: String,
    val updatedAt: String,
    val template: FirmName? = null,
    val client: String? = null,
    val company: String? = null,
    val versions: Int? = null,
    val lawyerName: String? = null,
    val lawyerNames: FirmName? = null,
    val consult: FirmConsult? = null,
    val forLawyerCount: Int? = null,
    val wantsCall: Boolean? = null,
    /** `review_requested` | `call_requested` | `client_replied`; older portals omit it (derived in [FirmInbox]). */
    val attention: String? = null,
    /** Portal this matter came from; set by the app after loading (never sent by the server). */
    val linkID: String? = null,
) {
    val lawyerDisplayName: String? get() = displayName(lawyerNames, lawyerName)
    /** Unique across linked portals (two firms may reuse a matter id). */
    val uid: String get() = (linkID ?: "") + "#" + id
}

@Serializable data class FirmMatterList(val serverTime: String? = null, val matters: List<FirmMatterSummary> = emptyList())
@Serializable data class FirmFlag(val id: String, val level: String? = null, val section: String? = null, val title: String? = null, val risk: String? = null)
@Serializable data class FirmVersionNotes(val changes: List<String>? = null, val flags: List<FirmFlag>? = null)
@Serializable data class FirmVersion(
    val n: Int, val markdown: String, val by: String? = null, val lawyer: String? = null,
    val signed: Boolean? = null, val pdfUrl: String? = null, val notes: FirmVersionNotes? = null,
)
@Serializable data class FirmForLawyer(val text: String, val section: String? = null, val flag: String? = null, val version: Int? = null)
@Serializable data class FirmTranscriptEntry(val role: String, val content: String, val name: String? = null, val at: String? = null, val version: Int? = null)
@Serializable data class FirmSignoff(val name: String? = null, val version: Int? = null, val at: String? = null)

@Serializable
data class FirmMatter(
    val id: String,
    val status: String,
    val updatedAt: String,
    val template: FirmName? = null,
    val client: String? = null,
    val company: String? = null,
    val lawyerName: String? = null,
    val lawyerNames: FirmName? = null,
    val consult: FirmConsult? = null,
    val transcript: List<FirmTranscriptEntry> = emptyList(),
    val versions: List<FirmVersion> = emptyList(),
    val flagState: Map<String, Map<String, String>>? = null,
    val forLawyer: List<FirmForLawyer>? = null,
    val signoff: FirmSignoff? = null,
) {
    val lawyerDisplayName: String? get() = displayName(lawyerNames, lawyerName)
    val latest: FirmVersion? get() = versions.maxByOrNull { it.n }
    val previous: FirmVersion? get() = latest?.let { l -> versions.filter { it.n < l.n }.maxByOrNull { it.n } }

    /** The version whose red flags were discussed with the client: the latest one with settlements, else the latest. */
    val flagsVersion: FirmVersion?
        get() = versions.filter { v -> !(flagState?.get(v.n.toString()).isNullOrEmpty()) && !(v.notes?.flags.isNullOrEmpty()) }
            .maxByOrNull { it.n } ?: latest

    /** Red flags of the latest version that the settled version did not have (by visible title). */
    val newFlags: List<FirmFlag>
        get() {
            val l = latest ?: return emptyList()
            val settled = flagsVersion ?: return emptyList()
            if (settled.n == l.n) return emptyList()
            val known = (settled.notes?.flags ?: emptyList()).map { FirmDiff.visible(it.title ?: "") }.toSet()
            return (l.notes?.flags ?: emptyList()).filter { FirmDiff.visible(it.title ?: "") !in known }
        }

    /** How a red flag of [flagsVersion] was settled: `noted`, `kept`, `lawyer`, or null (open). */
    fun settlement(flag: FirmFlag): String? = flagsVersion?.let { flagState?.get(it.n.toString())?.get(flag.id) }
}

@Serializable data class FirmSignoffResult(val ok: Boolean, val finalPdf: String? = null)
@Serializable data class FirmVersionResult(val ok: Boolean, val n: Int)
@Serializable data class FirmOK(val ok: Boolean)
