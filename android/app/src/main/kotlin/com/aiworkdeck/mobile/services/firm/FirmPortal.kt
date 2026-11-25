// SPDX-FileCopyrightText: 2026 北京公富信息技术有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
package com.aiworkdeck.mobile.services.firm

import com.aiworkdeck.contract.ContractCapabilities
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.HttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.TimeUnit

// Firm portal client and connection state, ported from iOS FirmPortal.swift (docs/specs/2026-11-19-firm-review.md).
// The account session goes only to allowlisted portals; a typed trial code lives in its own encrypted store.

/** HTTP transport, injectable for tests. */
fun interface FirmTransport {
    /** Sends the request; returns body and status. Throws on a network failure. */
    suspend fun send(request: Request): Pair<String, Int>
}

class OkHttpFirmTransport(private val client: OkHttpClient = defaultClient) : FirmTransport {
    override suspend fun send(request: Request): Pair<String, Int> = withContext(Dispatchers.IO) {
        client.newCall(request).execute().use { (it.body?.string() ?: "") to it.code }
    }
    companion object {
        val defaultClient: OkHttpClient by lazy { OkHttpClient.Builder().callTimeout(20, TimeUnit.SECONDS).build() }
    }
}

class FirmPortalClient(
    /** Portal id from the contract: `host` or `host/office`. */
    val portal: String,
    private val credential: String,
    private val transport: FirmTransport = OkHttpFirmTransport(),
    /** Tests only: send to this base (scheme/host/port) instead of the portal host. */
    private val baseOverride: HttpUrl? = null,
    private val allowed: List<String> = ContractCapabilities.firmPortals,
) {
    private suspend inline fun <reified T> request(path: String, query: Map<String, String> = emptyMap(), body: JsonObject? = null): T {
        if (portal !in allowed) throw FirmPortalError("host_not_allowed", 0)
        val (host, prefix) = FirmPortalLink.parts(portal)
        val url = HttpUrl.Builder().scheme(baseOverride?.scheme ?: "https").host(baseOverride?.host ?: host)
            .apply { baseOverride?.let { port(it.port) } }
            .encodedPath("$prefix/api/portal/$path")
            .apply { query.forEach { (k, v) -> addQueryParameter(k, v) } }.build()
        val builder = Request.Builder().url(url).header("Authorization", "Bearer $credential").header("Accept", "application/json")
        if (body != null) builder.post(body.toString().toRequestBody("application/json".toMediaType())) else builder.get()
        val (text, status) = try { transport.send(builder.build()) } catch (e: CancellationException) { throw e } catch (_: Exception) { throw FirmPortalError("network", 0) }
        if (status !in 200..299) {
            val code = runCatching { FirmJson.parseToJsonElement(text).jsonObject["error"]?.jsonPrimitive?.contentOrNull }.getOrNull()
            throw FirmPortalError(code ?: "http_$status", status)
        }
        return try { FirmJson.decodeFromString(text) } catch (_: Exception) { throw FirmPortalError("bad_response", status) }
    }

    suspend fun me(): FirmMe = request("me")
    suspend fun matters(): FirmMatterList = request("matters")
    suspend fun matter(id: String): FirmMatter = request("matter", mapOf("id" to id))
    suspend fun message(id: String, text: String, lawyer: String) {
        request<FirmOK>("matter/message", body = buildJsonObject { put("id", id); put("text", text); put("lawyer", lawyer) })
    }
    suspend fun consult(id: String, status: String) { request<FirmOK>("matter/consult", body = buildJsonObject { put("id", id); put("status", status) }) }
    suspend fun setStatus(id: String, status: String) { request<FirmOK>("matter/update", body = buildJsonObject { put("id", id); put("status", status) }) }
    suspend fun saveVersion(id: String, markdown: String, note: String, lawyer: String): Int =
        request<FirmVersionResult>("matter/version", body = buildJsonObject { put("id", id); put("markdown", markdown); put("note", note); put("lawyer", lawyer) }).n
    /** [details]: the lawyer's own `firm`, `title`, `admission` for portals without a roster; empty values are omitted. */
    suspend fun signoff(id: String, version: Int, name: String, details: Map<String, String> = emptyMap()): String? {
        val body = buildJsonObject {
            put("id", id); put("version", version); put("name", name)
            put("checks", buildJsonObject { put("conflicts", true); put("engagement", true); put("reviewed", true) })
            details.filterValues { it.isNotEmpty() }.forEach { (k, v) -> put(k, v) }
        }
        return request<FirmSignoffResult>("matter/signoff", body = body).finalPdf
    }
}

/** Trial codes, per account and portal. Saving must be verified: joining never falls back to sending the session. */
interface FirmTrialStore {
    fun read(account: String): String?
    fun save(account: String, code: String): Boolean
    fun clear(account: String)
}

/** Plain per-account settings: which portals are linked, and the lawyer's own review details. */
interface FirmSettings {
    fun links(key: String): List<String>
    fun setLinks(key: String, value: List<String>)
    fun string(key: String): String?
    fun setString(key: String, value: String?)
}

class MemoryFirmTrialStore : FirmTrialStore {
    val values = mutableMapOf<String, String>()
    var failSaves = false
    override fun read(account: String) = values[account]
    override fun save(account: String, code: String): Boolean { if (failSaves) return false; values[account] = code; return true }
    override fun clear(account: String) { values.remove(account) }
}

class MemoryFirmSettings : FirmSettings {
    val values = mutableMapOf<String, Any>()
    @Suppress("UNCHECKED_CAST") override fun links(key: String) = values[key] as? List<String> ?: emptyList()
    override fun setLinks(key: String, value: List<String>) { if (value.isEmpty()) values.remove(key) else values[key] = value }
    override fun string(key: String) = values[key] as? String
    override fun setString(key: String, value: String?) { if (value == null) values.remove(key) else values[key] = value }
}

/** What the UI shows for one linked portal. Error texts are contract keys (resolved with `tr` on screen). */
data class FirmLinkState(
    val me: FirmMe? = null,
    val matters: List<FirmMatterSummary> = emptyList(),
    val access: FirmAccess = FirmAccess.none,
    val loadErrorKey: String? = null,
    val lastErrorCode: String? = null,
    /** True once the matter list has loaded at least once. */
    val listed: Boolean = false,
    /** When the matter list last loaded successfully (epoch ms), shown as "Updated …" in the inbox. */
    val refreshedAt: Long? = null,
)

/** One linked portal for the signed-in account. */
class FirmLink(
    val portalID: String,
    val trialCode: String?,
    private val session: () -> String?,
    private val client: (portal: String, credential: String) -> FirmPortalClient,
) {
    private val _state = MutableStateFlow(FirmLinkState())
    val state: StateFlow<FirmLinkState> = _state.asStateFlow()
    /** Set when the link is dropped; a late reply for it is ignored. */
    @Volatile var closed = false

    fun client(): FirmPortalClient? = session()?.let { client(portalID, trialCode ?: it) }

    val firmName: String get() = _state.value.me?.firm?.text?.takeIf { it.isNotEmpty() } ?: portalID
    val isTrial: Boolean get() = _state.value.me?.kind == "trial"
    val asksDetails: Boolean get() = _state.value.me?.let { it.kind == "lawyer" && it.lawyerName?.text.isNullOrEmpty() } ?: false
    val needsYouCount: Int get() = _state.value.matters.count { FirmInbox.group(it) == FirmInbox.Group.needsYou }

    fun signer(m: FirmMatter): FirmSigner? = _state.value.me.let { me ->
        FirmIdentity.signer(me?.kind, me?.scope == "demo", me?.lawyerName?.text, me?.lawyerTitle?.text, me?.lawyerOffice?.text,
            me?.name, m.lawyerDisplayName, firmName)
    }

    suspend fun check() {
        val c = client()
        if (closed || c == null) { _state.update { it.copy(access = FirmAccess.none) }; return }
        val previous = _state.value.access
        if (previous != FirmAccess.approved) _state.update { it.copy(access = FirmAccess.checking) }
        try {
            val me = c.me()
            if (closed) return
            val access = FirmAccess.forStatus(me.status)
            _state.update { it.copy(me = me, access = access, matters = if (access == FirmAccess.approved) it.matters else emptyList()) }
            if (access == FirmAccess.approved) refresh()
        } catch (e: CancellationException) { throw e } catch (e: FirmPortalError) {
            if (closed) return
            val access = FirmAccess.after(e.code, previous)
            _state.update { it.copy(lastErrorCode = e.code, access = access, loadErrorKey = e.messageKey, matters = if (access == FirmAccess.approved) it.matters else emptyList()) }
        }
    }

    suspend fun refresh() {
        val c = client()
        if (closed || _state.value.access != FirmAccess.approved || c == null) return
        try {
            val list = c.matters().matters.map { it.copy(linkID = portalID) }
            if (closed) return
            _state.update { it.copy(matters = list, listed = true, loadErrorKey = null, refreshedAt = System.currentTimeMillis()) }
        } catch (e: CancellationException) { throw e } catch (e: FirmPortalError) {
            if (closed) return
            val access = FirmAccess.after(e.code, _state.value.access)
            _state.update { it.copy(access = access, loadErrorKey = e.messageKey, matters = if (access == FirmAccess.approved) it.matters else emptyList()) }
        }
    }
}

/**
 * All portals the signed-in account has linked. The Reviews tab merges their matters; each action goes to
 * the matter's own portal. Mirrors iOS FirmPortal.
 */
class FirmPortal(
    private val trials: FirmTrialStore,
    private val settings: FirmSettings,
    /** Current base URL and session of the signed-in account, or null when signed out. */
    private val identity: () -> Pair<String, String>?,
    /** The account server's user id for the current session (`/api/auth/me`). */
    private val verifiedUserId: suspend () -> Long,
    private val transport: FirmTransport = OkHttpFirmTransport(),
    private val baseOverride: HttpUrl? = null,
    private val allowed: List<String> = ContractCapabilities.firmPortals,
) {
    private val _links = MutableStateFlow<List<FirmLink>>(emptyList())
    val links: StateFlow<List<FirmLink>> = _links.asStateFlow()
    var scope: String? = null
        private set

    val access: FirmAccess get() = FirmAccess.combined(_links.value.map { it.state.value.access })
    val approved: List<FirmLink> get() = _links.value.filter { it.state.value.access == FirmAccess.approved }
    val matters: List<FirmMatterSummary> get() = approved.flatMap { it.state.value.matters }
    val loadErrorKey: String? get() = approved.firstNotNullOfOrNull { it.state.value.loadErrorKey }
    val listed: Boolean get() = approved.all { it.state.value.listed }
    val needsYouCount: Int get() = approved.sumOf { it.needsYouCount }
    fun link(portal: String?): FirmLink? = _links.value.firstOrNull { it.portalID == portal }

    /** Every link with its latest state; emits whenever a link is added, removed or changes. */
    @OptIn(ExperimentalCoroutinesApi::class)
    val overview: Flow<List<Pair<FirmLink, FirmLinkState>>> = _links.flatMapLatest { ls ->
        if (ls.isEmpty()) flowOf(emptyList()) else combine(ls.map { l -> l.state }) { states -> ls.zip(states.toList()) }
    }

    private val linksKey get() = scope?.let { "firm.links.$it" }

    private fun makeLink(portal: String, trialCode: String?) = FirmLink(portal, trialCode, { identity()?.second }) { p, credential ->
        FirmPortalClient(p, credential, transport, baseOverride, allowed)
    }

    private fun save() { linksKey?.let { settings.setLinks(it, _links.value.map(FirmLink::portalID)) } }

    /** Restores the account's saved links and checks access. Offline: stays hidden until the next retry. */
    private val restoring = kotlinx.coroutines.sync.Mutex()

    /** Concurrent callers (sign-in, Settings, Join) run one after another, never interleaved. */
    suspend fun restore() = restoring.withLock { restoreLocked() }

    private suspend fun restoreLocked() {
        reset()
        val (base, session) = identity() ?: return
        val id = runCatching { verifiedUserId() }.getOrDefault(0)
        // A placeholder id must never become a scope (it would be shared by every account on the device).
        if (id <= 0 || identity() != base to session) return
        val s = FirmIdentity.accountScope(id, base.trimEnd('/'))
        scope = s
        _links.value = settings.links("firm.links.$s").filter { it in allowed }
            .map { makeLink(it, trials.read(FirmIdentity.trialAccount(s, it))) }
        checkAll()
    }

    /** Links a portal (or re-links one with a new trial code). Returns null on success, else a contract key to show. */
    suspend fun connect(portal: String, trialCode: String? = null): String? {
        val s = scope ?: return "firm.error.network"
        val account = FirmIdentity.trialAccount(s, portal)
        val code = trialCode?.trim()?.ifEmpty { null }
        if (code != null) {
            if (!trials.save(account, code)) return "error.sessionSaveFailed"
        } else trials.clear(account)
        drop(portal)
        val link = makeLink(portal, code)
        _links.update { it + link }
        save()
        link.check()
        if (scope != s) return null
        val st = link.state.value
        // A rejected trial code ends as `revoked` on its first check; it is refused, not kept as a dead link.
        // (iOS keeps it: POLISH M25.)
        val badCode = code != null && st.lastErrorCode in setOf("unauthorized", "trial_expired")
        if (badCode || st.access == FirmAccess.failed || st.access == FirmAccess.none) {
            val key = if (badCode) "firm.trial.invalid" else st.loadErrorKey ?: "firm.error.network"
            disconnect(portal)
            return key
        }
        return null
    }

    private fun drop(portal: String) {
        _links.value.filter { it.portalID == portal }.forEach { it.closed = true }
        _links.update { list -> list.filter { it.portalID != portal } }
    }

    /** Unlinks one portal and forgets its trial code and saved details. */
    fun disconnect(portal: String) {
        drop(portal)
        scope?.let { s ->
            trials.clear(FirmIdentity.trialAccount(s, portal))
            for (f in DETAIL_FIELDS) settings.setString(FirmIdentity.detailsKey(s, portal) + f, null)
        }
        save()
    }

    /** Account deletion: every link and trial code leaves the device. */
    fun disconnectAll() { _links.value.map(FirmLink::portalID).forEach(::disconnect) }

    suspend fun checkAll() = coroutineScope { _links.value.map { async { it.check() } }.awaitAll(); Unit }

    /** Re-checks links that could not be established (offline launch, portal error). */
    suspend fun retry() = coroutineScope {
        _links.value.filter { it.state.value.access in setOf(FirmAccess.failed, FirmAccess.checking) }.map { async { it.check() } }.awaitAll(); Unit
    }

    suspend fun refresh() = coroutineScope { approved.map { async { it.refresh() } }.awaitAll(); Unit }

    /** Sign-out and account switch: forget in-memory state (stored links are account-scoped). */
    fun reset() {
        _links.value.forEach { it.closed = true }
        scope = null; _links.value = emptyList()
    }

    /** The lawyer's own review details for a portal without a roster. */
    fun savedDetails(portal: String): Map<String, String> = scope?.let { s ->
        DETAIL_FIELDS.associateWith { settings.string(FirmIdentity.detailsKey(s, portal) + it) ?: "" }
    } ?: emptyMap()
    fun saveDetails(portal: String, details: Map<String, String>) {
        val s = scope ?: return
        for (f in DETAIL_FIELDS) settings.setString(FirmIdentity.detailsKey(s, portal) + f, details[f] ?: "")
    }

    companion object { val DETAIL_FIELDS = listOf("title", "firm", "admission") }
}
