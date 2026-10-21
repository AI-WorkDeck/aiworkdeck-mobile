package com.aiworkdeck.mobile.services

import com.aiworkdeck.mobile.design.tr
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
class Unauthorized : Exception("unauthorized")

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
) {
    /** 固定主机，测试用。 */
    constructor(baseUrl: String, session: SessionStore, client: OkHttpClient = OkHttpClient()) : this({ baseUrl }, session, client)

    private val baseUrl: String get() = baseUrlProvider()
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }
    private val jsonType = "application/json; charset=utf-8".toMediaType()

    suspend fun accountLogin(account: String, password: String): LoginResult =
        login(post("/api/auth/account-login", buildJsonObject { put("account", account); put("password", password) }))

    suspend fun sendLoginCode(phone: String) { envelope(post("/api/auth/sms-login/send-code", buildJsonObject { put("phone", phone) })) }
    suspend fun verifyLoginCode(phone: String, code: String): LoginResult =
        login(post("/api/auth/sms-login/verify", buildJsonObject { put("phone", phone); put("code", code) }))
    suspend fun sendMailLoginCode(email: String) { envelope(post("/api/auth/mail-login/send-code", buildJsonObject { put("email", email) })) }
    suspend fun verifyMailLoginCode(email: String, code: String): LoginResult =
        login(post("/api/auth/mail-login/verify", buildJsonObject { put("email", email); put("code", code) }))
    suspend fun deleteAccount() { envelope(post("/api/auth/account/delete", buildJsonObject {})) }
    fun logout() = session.clear()
    /** 本机有没有会话。只判断「有没有」，是否还有效由第一次真实请求的 401 发现。 */
    fun hasSession(): Boolean = session.current() != null

    suspend fun myProjects(): List<RelayProject> = bare<List<CatalogProject>>("/api/mobile/catalog").map { it.toRelayProject() }
    suspend fun mediaUsage(): MediaUsage = bare("/api/mobile/media/usage")
    /** 统一账户余额。成功回裸对象、失败回信封，两者都是 JsonObject，靠 bare() 里探 code 字段区分。 */
    suspend fun billingBalance(): BillingBalance = bare("/api/mobile/billing/balance")
    suspend fun mediaStatus(ids: List<String>): List<MediaStatus> =
        if (ids.isEmpty()) emptyList() else bare("/api/mobile/media/status?clientMediaIds=" + ids.joinToString(","))

    suspend fun upload(file: File, deviceId: String, projectKey: String, clientMediaId: String, fileName: String,
                       mediaType: String, capturedAt: String, onProgress: (Double) -> Unit): UploadResult = withContext(Dispatchers.IO) {
        val body = MultipartBody.Builder().setType(MultipartBody.FORM)
            .addFormDataPart("deviceId", deviceId).addFormDataPart("projectKey", projectKey)
            .addFormDataPart("clientMediaId", clientMediaId).addFormDataPart("fileName", fileName)
            .addFormDataPart("mediaType", mediaType).addFormDataPart("capturedAt", capturedAt)
            .addFormDataPart("file", fileName, ProgressBody(file, onProgress)).build()
        val text = execute(Request.Builder().url(baseUrl + "/api/mobile/media").post(body))
        val el = json.parseToJsonElement(text).jsonObject
        checkEnvelopeCode(el)
        json.decodeFromJsonElement<UploadResult>(el)
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
    private suspend fun execute(b: Request.Builder): String = withContext(Dispatchers.IO) {
        check(accountActive()) { tr("files.error.closed") }
        kotlinx.coroutines.currentCoroutineContext().ensureActive()
        session.current()?.let { b.header("X-Session-Id", it) }
        b.header("X-App-Language", languageProvider())
        client.newCall(b.build()).execute().use { resp ->
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
