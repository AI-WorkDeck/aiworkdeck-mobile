package com.aiworkdeck.mobile.services

import com.aiworkdeck.mobile.design.tr
import com.aiworkdeck.mobile.model.ArchiveMove
import com.aiworkdeck.mobile.model.ArchiveMoveAccount
import com.aiworkdeck.mobile.model.ArchiveMoveRegistrationRejected
import com.aiworkdeck.mobile.model.ArchiveMoveReply
import com.aiworkdeck.mobile.model.ArchiveMoveService
import com.aiworkdeck.mobile.model.CaptureItem
import com.aiworkdeck.mobile.model.RelayProject
import com.aiworkdeck.mobile.model.CatalogProject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import okio.BufferedSink
import java.io.File

/**
 * kind/outTradeNo 仅信封分支（[checkEnvelopeCode]）才会带上；网络层/HTTP 层失败
 * （[execute] 里的非 2xx）两者恒为 null——那两种失败压根没有信封可读。
 */
class ApiError(val code: Int, message: String, val kind: EnvelopeKind? = null, val outTradeNo: String? = null) : Exception(message)
class Unauthorized : Exception(tr("error.unauthorized"))

/**
 * [baseUrlProvider] 每次发请求现取：主机跟着账号区域走（dev-board#837），区域在登录页换了，
 * 进程里这唯一一份 Backend（App 里装配、Worker 也用它）下一个请求就打新主机。
 */
class Backend(
    private val baseUrlProvider: () -> String,
    private val session: SessionStore,
    private val client: OkHttpClient = OkHttpClient(),
    /** 请求头 X-App-Language 的值（zh-CN / en-US），同样每次现取，跟着区域走。 */
    private val languageProvider: () -> String = { AccountRegion.cn.appLanguage },
    private val accountActive: () -> Boolean = { true },
) : ArchiveMoveService {
    /** 固定主机，测试用。 */
    constructor(baseUrl: String, session: SessionStore, client: OkHttpClient = OkHttpClient()) : this({ baseUrl }, session, client)

    private val baseUrl: String get() = baseUrlProvider()
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }
    private val jsonType = "application/json; charset=utf-8".toMediaType()

    suspend fun accountLogin(account: String, password: String): LoginResult =
        login(post("/api/auth/account-login", buildJsonObject { put("account", account); put("password", password) }))

    suspend fun sendLoginCode(phone: String) { envelope(post("/api/auth/sms-login/send-code", buildJsonObject { put("phone", phone) })) }
    suspend fun sendMailLoginCode(email: String) { envelope(post("/api/auth/mail-login/send-code", buildJsonObject { put("email", email) })) }
    suspend fun deleteAccount() { envelope(post("/api/auth/account/delete", buildJsonObject {})) }
    fun logout() { CloudEpoch.accountChanged(); session.clear() }
    /** 本机有没有会话。只判断「有没有」，是否还有效由第一次真实请求的 401 发现。 */
    fun hasSession(): Boolean = session.current() != null

    suspend fun defaultProject(): RelayProject {
        val identity = session.current()
        val result = envelope(post("/api/mobile/catalog/default", buildJsonObject {}))
        if (identity != session.current()) throw Unauthorized()
        return json.decodeFromJsonElement<CatalogProject>(result["data"] ?: throw ApiError(1, tr("error.badResponse"))).toRelayProject()
    }

    suspend fun myProjects(): List<RelayProject> = bare<List<CatalogProject>>("/api/mobile/catalog").map { it.toRelayProject() }
    suspend fun mediaUsage(): MediaUsage = bare("/api/mobile/media/usage")
    /** 临时项目 has no desktop behind it: uploading there needs persistent cloud storage. Fails safe. */
    suspend fun persistentCloudWritable(): Boolean = try { mediaUsage().persistentCloudWritable }
        catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (_: Exception) { false }
    /** 统一账户余额。成功回裸对象、失败回信封，两者都是 JsonObject，靠 bare() 里探 code 字段区分。 */
    suspend fun cloudBillingState(): PostpaidState = bare("/api/mobile/billing/cloud-state")
    suspend fun acceptPostpaid(policyVersion: String, resume: Boolean = false): PostpaidState {
        val body = buildJsonObject { put("policyVersion", policyVersion) }.toString().toRequestBody("application/json".toMediaType())
        val result = json.parseToJsonElement(execute(Request.Builder().url(baseUrl + if (resume) "/api/mobile/billing/resume-cloud" else "/api/mobile/billing/postpaid-accept").post(body))).jsonObject
        checkEnvelopeCode(result)
        return json.decodeFromJsonElement(result)
    }
    suspend fun reconnectCloud() = withContext(Dispatchers.IO) {
        val id = session.current() ?: throw Unauthorized()
        val request = Request.Builder().url(baseUrl + "/api/mobile/media").header("X-Session-Id", id).post("".toRequestBody()).build()
        CloudEpoch.reconnect(request, client)
    }
    suspend fun billingBalance(): BillingBalance = bare("/api/mobile/billing/balance")
    /** 充值建单：大陆默认 channel=wxpay-app，Play 传 channel=googleplay + productId。成功是裸对象，失败是信封（code 1 + kind）。 */
    suspend fun billingRecharge(
        amountCents: Long,
        idempotencyKey: String,
        channel: String = "wxpay-app",
        productId: String? = null,
    ): RechargeOrder {
        val result = json.parseToJsonElement(post("/api/mobile/billing/recharge", buildJsonObject {
            put("amountCents", amountCents)
            put("idempotencyKey", idempotencyKey)
            put("channel", channel)
            if (!productId.isNullOrBlank()) put("productId", productId)
        })).jsonObject
        checkEnvelopeCode(result)
        return json.decodeFromJsonElement(result)
    }
    /** Google Play 验单入账（dev-board#665）。只有 paid=true 端上才 consumeAsync。 */
    suspend fun billingConfirmGooglePlay(
        productId: String,
        purchaseToken: String,
        outTradeNo: String? = null,
    ): RechargeStatus {
        val result = json.parseToJsonElement(post("/api/mobile/billing/recharge/confirm-googleplay", buildJsonObject {
            if (!outTradeNo.isNullOrBlank()) put("outTradeNo", outTradeNo.trim())
            put("productId", productId)
            put("purchaseToken", purchaseToken)
        })).jsonObject
        checkEnvelopeCode(result)
        return json.decodeFromJsonElement(result)
    }
    suspend fun billingRechargeStatus(outTradeNo: String): RechargeStatus =
        bare("/api/mobile/billing/recharge/status?outTradeNo=" + java.net.URLEncoder.encode(outTradeNo, "UTF-8"))
    suspend fun mediaStatus(ids: List<String>): List<MediaStatus> =
        if (ids.isEmpty()) emptyList() else bare("/api/mobile/media/status?clientMediaIds=" + ids.joinToString(","))

    suspend fun upload(file: File, deviceId: String, projectKey: String, clientMediaId: String, fileName: String,
                       mediaType: String, capturedAt: String, organize: Boolean = false, onProgress: (Double) -> Unit): UploadResult = withContext(Dispatchers.IO) {
        val body = MultipartBody.Builder().setType(MultipartBody.FORM)
            .addFormDataPart("deviceId", deviceId).addFormDataPart("projectKey", projectKey)
            .addFormDataPart("clientMediaId", clientMediaId).addFormDataPart("fileName", fileName)
            .addFormDataPart("mediaType", mediaType).addFormDataPart("capturedAt", capturedAt)
            .addFormDataPart("organize", organize.toString())
            .addFormDataPart("file", fileName, ProgressBody(file, onProgress)).build()
        val text = execute(Request.Builder().url(baseUrl + "/api/mobile/media").post(body), upload = true)
        val el = json.parseToJsonElement(text).jsonObject
        checkEnvelopeCode(el)
        json.decodeFromJsonElement<UploadResult>(el)
    }

    // MARK: - 已上传件改投项目（镜像 iOS API.registerMove / moveStatus / retryMove / uploadMoveTarget）

    /** 当前主机与会话；没登录为 null。 */
    fun identity(): Pair<String, String>? = session.current()?.let { baseUrl to it }

    /** 向服务端核实当前会话属于哪个用户（/api/auth/me）。移动事务要按用户而不是按会话绑定。 */
    suspend fun verifiedUserId(): Long {
        val result = envelope(execute(Request.Builder().url(baseUrl + "/api/auth/me").get()))
        val id = result["data"]?.jsonObject?.get("id")?.jsonPrimitive?.longOrNull
        if (id == null || id <= 0) throw Unauthorized()
        return id
    }

    override suspend fun registerMove(move: ArchiveMove, account: ArchiveMoveAccount): ArchiveMoveReply =
        moveRequest(account, "", buildJsonObject {
            put("requestId", move.requestId); put("sourceClientMediaId", move.sourceClientMediaId)
            put("targetClientMediaId", move.targetClientMediaId)
            put("sourceDeviceId", move.source.deviceId); put("sourceProjectKey", move.source.key)
            put("targetDeviceId", move.target.deviceId); put("targetProjectKey", move.target.key)
            put("sha256", move.sha256); put("fileSize", move.fileSize)
        }, registration = true)

    override suspend fun moveStatus(move: ArchiveMove, account: ArchiveMoveAccount): ArchiveMoveReply =
        moveRequest(account, "/" + move.requestId.lowercase(), null)

    override suspend fun retryMove(move: ArchiveMove, account: ArchiveMoveAccount): ArchiveMoveReply =
        moveRequest(account, "/" + move.requestId.lowercase() + "/retry", buildJsonObject {})

    /** 目标那一份按目标回执的 clientMediaId 上传；用冻结的账号凭据，不跟着界面上换的账号走。 */
    override suspend fun uploadMoveTarget(item: CaptureItem, move: ArchiveMove, account: ArchiveMoveAccount) {
        val frozen = MemorySessionStore().also { it.save(account.sessionId) }
        Backend({ account.baseUrl }, frozen, client, languageProvider).upload(
            file = item.localFile, deviceId = move.target.deviceId, projectKey = move.target.key,
            clientMediaId = move.targetClientMediaId, fileName = UploadNaming.fileName(item),
            mediaType = item.kind.mediaType, capturedAt = item.manifest.capturedAt, organize = false,
        ) {}
    }

    /** body 为 null 时发 GET，否则 POST。 */
    private suspend fun moveRequest(account: ArchiveMoveAccount, path: String, body: JsonObject?,
                                    registration: Boolean = false): ArchiveMoveReply = withContext(Dispatchers.IO) {
        val builder = Request.Builder().url(account.baseUrl + "/api/mobile/media/moves" + path)
            .header("X-Session-Id", account.sessionId).header("X-App-Language", languageProvider())
        if (body != null) builder.post(body.toString().toRequestBody(jsonType)) else builder.get()
        val request = CloudEpoch.authorize(builder.build(), client)
        client.newCall(request).execute().use { resp ->
            kotlinx.coroutines.currentCoroutineContext().ensureActive()
            decodeMoveResponse(resp.body?.string() ?: "", resp.code, registration)
        }
    }

    companion object {
        private val moveJson = Json { ignoreUnknownKeys = true; explicitNulls = false }

        /**
         * 超时、5xx、回包坏、笼统的 code=1 都**不**解锁一次不确定的登记：事务可能已在服务端提交。
         * 只有 2xx–4xx 且信封 kind 明确为 MOVE_NOT_REGISTERED 才算被拒。纯函数，JVM 单测直接调。
         */
        fun decodeMoveResponse(text: String, statusCode: Int, registration: Boolean): ArchiveMoveReply {
            val envelope = runCatching { moveJson.parseToJsonElement(text).jsonObject }.getOrNull()
            val code = envelope?.get("code")?.jsonPrimitive?.intOrNull
            val message = envelope?.get("message")?.jsonPrimitive?.contentOrNull
            val kind = envelope?.get("kind")?.jsonPrimitive?.contentOrNull
            if (registration && statusCode in 200..499 && code != null && code != 0 && kind == "MOVE_NOT_REGISTERED") {
                throw ArchiveMoveRegistrationRejected(message ?: tr("queue.moveUnavailable"))
            }
            val data = envelope?.get("data")
            val reply = if (statusCode in 200..299 && code == 0 && data != null && data !is JsonNull)
                runCatching { moveJson.decodeFromJsonElement<ArchiveMoveReply>(data) }.getOrNull() else null
            return reply ?: throw ApiError(1, message ?: tr("queue.moveUnavailable"))
        }
    }

    fun accountSnapshot(): Backend {
        val url = baseUrl
        val id = session.current()
        val language = languageProvider()
        val frozen = MemorySessionStore().also { if (id != null) it.save(id) }
        return Backend({ url }, frozen, client, { language }) { id != null && baseUrl == url && session.current() == id }
    }
    suspend fun backupConsent(): BackupConsent = bare("/api/mobile/backup-consent")
    suspend fun setBackupConsent(enabled: Boolean): BackupConsent {
        val body = buildJsonObject { put("enabled", enabled); put("consentVersion", com.aiworkdeck.contract.ContractCapabilities.backupConsentVersion) }
        val result = execute(Request.Builder().url(baseUrl + "/api/mobile/backup-consent").put(body.toString().toRequestBody(jsonType)))
        val value = json.parseToJsonElement(result).jsonObject
        checkEnvelopeCode(value)
        return json.decodeFromJsonElement(value)
    }
    fun projectFiles(root: File): ProjectFilesService {
        val url = baseUrl
        val id = session.current() ?: throw Unauthorized()
        return ProjectFilesService(url, id, languageProvider(), root, client) { baseUrl == url && session.current() == id }
    }

    fun personalAccountScope(): String? = session.current()?.takeIf { accountActive() }?.let { id ->
        java.security.MessageDigest.getInstance("SHA-256").digest((baseUrl + ":" + id).toByteArray()).joinToString("") { "%02x".format(it) }
    }
    suspend fun reportAssistant(conversationId: String, description: String): Long = withContext(Dispatchers.IO) {
        val payload = buildJsonObject {
            put("kind", "BUG"); put("text", description.trim()); put("page", "mobile/personal/assistant")
            put("clientContext", buildJsonObject {
                put("type", "ai-content-report"); put("platform", "android")
                put("conversationId", java.util.UUID.fromString(conversationId).toString())
            })
        }
        val body = MultipartBody.Builder().setType(MultipartBody.FORM).addFormDataPart("payload", payload.toString()).build()
        val result = envelope(execute(Request.Builder().url(baseUrl + "/api/feedback").post(body)))
        result["data"]?.jsonObject?.get("id")?.jsonPrimitive?.longOrNull?.takeIf { it > 0 }
            ?: throw ApiError(1, tr("error.badResponse"))
    }
    suspend fun assistantReport(id: Long): AssistantReport? = withContext(Dispatchers.IO) {
        require(id > 0)
        val account = session.current() ?: throw Unauthorized()
        val host = baseUrl
        check(accountActive()) { tr("files.error.closed") }
        val request = Request.Builder().url(host + "/api/feedback/mine")
            .header("X-Session-Id", account).header("X-App-Language", languageProvider()).get().build()
        val transport = client.newBuilder().followRedirects(false).build()
        transport.newCall(request).execute().use { response ->
            val text = response.body?.string() ?: ""
            check(accountActive() && session.current() == account && baseUrl == host) { tr("files.error.closed") }
            kotlinx.coroutines.currentCoroutineContext().ensureActive()
            if (!response.isSuccessful) throw ApiError(response.code, tr("error.network"))
            val result = envelope(text)
            val items = result["data"]?.jsonObject?.get("items")?.jsonArray
                ?: throw ApiError(1, tr("error.badResponse"))
            val reports = items.map { json.decodeFromJsonElement<AssistantReport>(it) }
            check(accountActive() && session.current() == account && baseUrl == host) { tr("files.error.closed") }
            reports.firstOrNull { it.id == id && it.aiContentReport }
        }
    }
    suspend fun personalStatus(): PersonalStatus = personal("assistant/status")
    suspend fun personalCalendar(): PersonalCalendar = personal("calendar/events")
    suspend fun personalSettings(feature: String, enabled: Boolean): PersonalSettings = personal(feature + "/settings", "PUT",
        buildJsonObject { put("enabled", enabled); put("consentVersion", com.aiworkdeck.contract.ContractCapabilities.personalConsentVersion) })
    suspend fun personalDesktopCopy(request: DesktopCopyRequest): DesktopCopyReceipt = personal<DesktopCopyReceipt>(
        "assistant/conversations/" + java.util.UUID.fromString(request.sourceConversationId) + "/copy-to-desktop", "POST",
        buildJsonObject { put("requestId", request.requestId); put("targetProjectUid", request.targetProjectUid); put("targetDeviceId", request.targetDeviceId); put("targetProjectKey", request.targetProjectKey) }).also { it.validate(request) }
    suspend fun personalDesktopCopyStatus(request: DesktopCopyRequest): DesktopCopyReceipt = personal<DesktopCopyReceipt>(
        "assistant/desktop-copies/" + java.util.UUID.fromString(request.requestId)).also { it.validate(request) }
    suspend fun personalDesktopCopies(id: String): List<DesktopCopyReceipt> = personal<List<DesktopCopyReceipt>>(
        "assistant/conversations/" + java.util.UUID.fromString(id) + "/desktop-copies").also { list -> list.forEach { check(it.sourceConversationId == id) { tr("error.badResponse") }; it.validate(it.request) } }
    suspend fun personalCopy(id: String, targetProjectId: Long): PersonalCopyResult = personal(
        "assistant/conversations/" + java.util.UUID.fromString(id) + "/copy-to-project", "POST",
        buildJsonObject { put("targetProjectId", targetProjectId) })
    suspend fun personalHistory(id: String): PersonalHistory = personal("assistant/conversations/" + java.util.UUID.fromString(id))
    suspend fun personalRequest(id: String): PersonalReply = awaitPersonalReply(personal("assistant/requests/" + java.util.UUID.fromString(id)), id)
    suspend fun personalChat(question: PersonalQuestion): PersonalReply = awaitPersonalReply(
        personal("assistant/chat", "POST", json.encodeToJsonElement(question).jsonObject), question.requestId).also {
            if (it.status != "completed") throw ApiError(1, tr("error.network"))
        }
    private suspend fun awaitPersonalReply(initial: PersonalReply, requestId: String): PersonalReply {
        var reply = initial
        var attempts = 0
        while (reply.status == "running" && attempts++ < 120) {
            kotlinx.coroutines.delay(2000)
            check(reply.requestId == requestId) { tr("error.badResponse") }
            reply = personal("assistant/requests/" + java.util.UUID.fromString(requestId))
        }
        check(reply.requestId == requestId) { tr("error.badResponse") }
        return reply
    }
    private suspend inline fun <reified T> personal(path: String, method: String = "GET", body: JsonObject? = null): T = withContext(Dispatchers.IO) {
        val account = session.current() ?: throw Unauthorized()
        val host = baseUrl
        check(accountActive()) { tr("files.error.closed") }
        val request = Request.Builder().url(host + "/api/mobile/" + path)
            .header("X-Session-Id", account).header("X-App-Language", languageProvider())
        if (body != null) request.method(method, body.toString().toRequestBody(jsonType))
        val transport = client.newBuilder().readTimeout(240, java.util.concurrent.TimeUnit.SECONDS).callTimeout(250, java.util.concurrent.TimeUnit.SECONDS).followRedirects(false).build()
        transport.newCall(request.build()).execute().use { response ->
            check(accountActive() && session.current() == account && baseUrl == host) { tr("files.error.closed") }
            kotlinx.coroutines.currentCoroutineContext().ensureActive()
            val text = response.body?.string() ?: ""
            if (!response.isSuccessful) throw ApiError(response.code, tr("error.network"))
            val result = envelope(text)
            json.decodeFromJsonElement<T>(result["data"] ?: throw ApiError(1, tr("error.badResponse")))
        }
    }

    // ---- 内部 ----
    private suspend fun post(path: String, body: JsonObject): String =
        execute(Request.Builder().url(baseUrl + path).post(body.toString().toRequestBody(jsonType)))
    private suspend inline fun <reified T> bare(path: String): T {
        val text = execute(Request.Builder().url(baseUrl + path).get())
        val el = json.parseToJsonElement(text)
        if (el is JsonObject) checkEnvelopeCode(el)   // 未登录 4010 信封
        return json.decodeFromJsonElement(el)
    }
    private fun envelope(text: String): JsonObject { val el = json.parseToJsonElement(text).jsonObject; checkEnvelopeCode(el); return el }
    private fun login(text: String): LoginResult {
        val r = json.decodeFromJsonElement<LoginResult>(envelope(text)["data"] ?: throw ApiError(1, tr("error.server", mapOf("code" to 1))))
        if (r.sessionId.isBlank() || r.user.id <= 0) throw ApiError(1, tr("error.loginNoData"))
        CloudEpoch.accountChanged()
        session.save(r.sessionId); return r
    }
    /** 全站信封：code 0 成功；4010 未登录（清会话）；其他为业务错误。裸数组不进这里。
     *  kind/outTradeNo 是 billing 端点的机器可读判别位，缺席时解成 null（不猜）。 */
    private fun checkEnvelopeCode(el: JsonObject) {
        val code = el["code"]?.jsonPrimitive?.intOrNull ?: return
        if (code == 4010) { session.clear(); throw Unauthorized() }
        if (code != 0) throw ApiError(
            code,
            el["message"]?.jsonPrimitive?.contentOrNull ?: tr("error.server", mapOf("code" to code)),
            EnvelopeKind.fromRaw(el["kind"]?.jsonPrimitive?.contentOrNull),
            el["outTradeNo"]?.jsonPrimitive?.contentOrNull,
        )
    }
    private suspend fun execute(b: Request.Builder, upload: Boolean = false): String = withContext(Dispatchers.IO) {
        check(accountActive()) { tr("files.error.closed") }
        kotlinx.coroutines.currentCoroutineContext().ensureActive()
        session.current()?.let { b.header("X-Session-Id", it) }
        b.header("X-App-Language", languageProvider())
        val transport = if (upload) client.newBuilder().readTimeout(120, java.util.concurrent.TimeUnit.SECONDS).build() else client
        val origin = baseUrl
        val request = CloudEpoch.authorize(b.build(), transport, expectedGeneration = kotlinx.coroutines.currentCoroutineContext()[CloudWriteGeneration]?.value)
        check(accountActive() && origin == baseUrl && request.header("X-Session-Id") == session.current()) { tr("files.error.closed") }
        transport.newCall(request).execute().use { resp ->
            val text = resp.body?.string() ?: ""
            check(accountActive()) { tr("files.error.closed") }
            kotlinx.coroutines.currentCoroutineContext().ensureActive()
            if (!resp.isSuccessful) throw ApiError(resp.code, tr("error.server", mapOf("code" to resp.code)))
            text
        }
    }
}

/** 带进度回调的文件体。 */
class ProgressBody(private val file: File, private val onProgress: (Double) -> Unit) : RequestBody() {
    override fun contentType() = "application/octet-stream".toMediaType()
    override fun contentLength() = file.length()
    override fun writeTo(sink: BufferedSink) {
        val total = file.length().coerceAtLeast(1); var sent = 0L
        file.inputStream().use { input ->
            val buf = ByteArray(64 * 1024)
            while (true) { val n = input.read(buf); if (n < 0) break; sink.write(buf, 0, n); sent += n; onProgress(sent.toDouble() / total) }
        }
    }
}
