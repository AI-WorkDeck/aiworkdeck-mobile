package com.aiworkdeck.mobile.services

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.selects.select
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/*
 * 安卓大陆版微信支付 APP 支付充值（dev-board#428）。这里只放不依赖 Android 的部分（JVM 单测覆盖）：
 * 线上形状、运行时开关、待确认订单的落盘与恢复、查单轮询。OpenSDK 调用在 cn 源集
 * （WxPayLauncherFactory / WXPayEntryActivity），界面在 features/settings/RechargeScreen.kt。
 *
 * 流程与小程序 / iOS 同一套：幂等键先落盘 → 建单拿七个 PayReq 字段 → 调起微信 →
 * **SDK 回调不作数**，一律轮询 /recharge/status 直到 paid → 刷新余额。到账靠微信支付回调官网入账，
 * 端上没确认到也不会丢钱，只是界面停在「到账稍有延迟」。
 */

/** POST /api/mobile/billing/recharge 的裸响应。字段名与 contract/schema/billing.schema.json 的 recharge 段逐字一致，缺席即 null。 */
@Serializable
data class RechargeOrder(
    val present: String,
    val outTradeNo: String,
    val amountCents: Long,
    val codeUrl: String? = null,
    val qrCode: String? = null,
    val redirectUrl: String? = null,
    val signData: String? = null,
    val paySig: String? = null,
    val signature: String? = null,
    val appAccountToken: String? = null,
    val appId: String? = null,
    val partnerId: String? = null,
    val prepayId: String? = null,
    val packageValue: String? = null,
    val nonceStr: String? = null,
    val timeStamp: String? = null,
    val sign: String? = null,
) {
    /** present=app 且七个字段齐全才给；少一个微信都调不起来，不如不调。 */
    fun appPayParams(): AppPayParams? {
        if (present != "app") return null
        return AppPayParams(
            appId?.takeIf { it.isNotEmpty() } ?: return null,
            partnerId?.takeIf { it.isNotEmpty() } ?: return null,
            prepayId?.takeIf { it.isNotEmpty() } ?: return null,
            packageValue?.takeIf { it.isNotEmpty() } ?: return null,
            nonceStr?.takeIf { it.isNotEmpty() } ?: return null,
            timeStamp?.takeIf { it.isNotEmpty() } ?: return null,
            sign?.takeIf { it.isNotEmpty() } ?: return null,
        )
    }
}

/** OpenSDK PayReq 的七个字段，原样透传，端上不重算、不改写。 */
data class AppPayParams(
    val appId: String, val partnerId: String, val prepayId: String, val packageValue: String,
    val nonceStr: String, val timeStamp: String, val sign: String,
)

/** GET /api/mobile/billing/recharge/status 的裸响应。 */
@Serializable
data class RechargeStatus(val status: String, val paid: Boolean, val amountCents: Long)

// ---- 运行时开关 ----

/**
 * 契约里安卓的 recharge 仍是 "external"：静态开关不翻，微信 APP 支付在运行时打开。
 * 全部满足才走端内支付，否则保持今天的行为（只弹「去小程序充值」说明）：
 *  - 大陆版、大陆账号（国际站不收人民币）；
 *  - 本包带了开放平台 AppID（BuildConfig.WXPAY_APP_ID，缺省空串）；
 *  - 服务端这次进程里没回过「通道不可用」（[isChannelUnavailable]）；
 *  - 余额没回 DISABLED / REVIEW_ACCOUNT（本部署没开通计费 / 审核演示账号，见 billing.schema.json 的 UI 映射）。
 */
fun wxpayAppEnabled(flavor: String, region: AccountRegion, appId: String, serverUnavailable: Boolean, balanceKind: EnvelopeKind?): Boolean =
    flavor == "cn" && region == AccountRegion.cn && appId.isNotBlank() && !serverUnavailable &&
        balanceKind != EnvelopeKind.DISABLED && balanceKind != EnvelopeKind.REVIEW_ACCOUNT

/**
 * 下单回这几种就当本部署没开这条通道：信封 DISABLED（计费未配，或官网未配 WXPAY_APP_APPID——
 * 后端把官网的 503 channel_unavailable 翻成 DISABLED）/ REVIEW_ACCOUNT（审核账号）。
 * 裸 HTTP 503（网关维护、过载）是瞬时故障，与 UNAVAILABLE 一样只提示稍后再试，不能据此把通道关到重启。
 */
fun isChannelUnavailable(e: Throwable): Boolean = e is ApiError &&
    (e.kind == EnvelopeKind.DISABLED || e.kind == EnvelopeKind.REVIEW_ACCOUNT)

/** 进程级记号：服务端回过通道不可用，本进程里不再打开充值页，直接给说明。重启 App 再试一次。 */
object WxPayChannel {
    @Volatile var serverUnavailable: Boolean = false
}

// ---- SDK 回调 ----

enum class WxPayOutcome { SUCCESS, CANCELLED, FAILED, NOT_INSTALLED, UNKNOWN }

/** BaseResp.errCode：0 成功、-2 用户取消，其余（-1 签名/配置错误等）一律失败。 */
fun wxPayOutcome(errCode: Int): WxPayOutcome = when (errCode) {
    0 -> WxPayOutcome.SUCCESS
    -2 -> WxPayOutcome.CANCELLED
    else -> WxPayOutcome.FAILED
}

/** WXPayEntryActivity 把回调结果投到这里，充值页在调起微信前订阅。进程级，跨 Activity。 */
object WxPayResults {
    private val flow = MutableSharedFlow<WxPayOutcome>(replay = 1, onBufferOverflow = BufferOverflow.DROP_OLDEST)
    val results: SharedFlow<WxPayOutcome> = flow.asSharedFlow()
    fun deliver(outcome: WxPayOutcome) { flow.tryEmit(outcome) }
    /** 调起微信前清掉上一笔的回放，免得把旧结果当成这一笔的。 */
    @OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
    fun reset() = flow.resetReplayCache()
}

/**
 * 等微信回调。微信偶尔不回调（被杀、用户从最近任务切回来），所以回到前台 [graceMs] 后还没等到，
 * 就按 UNKNOWN 交给查单——反正到账只认查单。
 */
suspend fun awaitWxPayResult(results: Flow<WxPayOutcome>, resumed: Flow<Unit>, graceMs: Long = 3000): WxPayOutcome = coroutineScope {
    val result = async { results.first() }
    val fallback = async { resumed.first(); delay(graceMs); WxPayOutcome.UNKNOWN }
    select { result.onAwait { it }; fallback.onAwait { it } }.also { result.cancel(); fallback.cancel() }
}

// ---- 待确认订单 ----

/** 落盘的待确认订单：幂等键在发请求前就写下，建单成功后补上 outTradeNo。按账号隔离。 */
@Serializable
data class PendingRecharge(val scope: String, val idempotencyKey: String, val amountCents: Long, val outTradeNo: String? = null)

/**
 * 只有一个槽位。微信 APP 支付由官网收微信回调入账，端上丢了这条记录也不丢钱，
 * 它只是让「付完被杀 / 断网」之后重进充值页还能把「到账了没有」告诉用户（对齐 iOS「恢复未完成的购买」）。
 */
class PendingRechargeStore(
    private val read: () -> String?,
    private val write: (String?) -> Unit,
    private val newKey: () -> String = { java.util.UUID.randomUUID().toString() },
) {
    private val json = Json { ignoreUnknownKeys = true }

    fun current(scope: String): PendingRecharge? = read()
        ?.let { try { json.decodeFromString<PendingRecharge>(it) } catch (_: Exception) { null } }
        ?.takeIf { it.scope == scope }

    /** 同账号同金额复用同一把键（取消后再点不会变成两笔单）；换金额或换账号就换新键并先落盘。 */
    @Synchronized fun takeKey(scope: String, amountCents: Long): String {
        current(scope)?.takeIf { it.amountCents == amountCents }?.let { return it.idempotencyKey }
        val key = newKey()
        write(json.encodeToString(PendingRecharge(scope, key, amountCents)))
        return key
    }

    @Synchronized fun attach(scope: String, idempotencyKey: String, outTradeNo: String) {
        val p = current(scope)?.takeIf { it.idempotencyKey == idempotencyKey } ?: return
        write(json.encodeToString(p.copy(outTradeNo = outTradeNo)))
    }

    @Synchronized fun clear(scope: String) { if (current(scope) != null) write(null) }
}

// ---- 查单 ----

enum class PollOutcome { PAID, CLOSED, PENDING }

/**
 * 轮询查单：paid 就停；closed / expired 是终态也停；单次查失败不打断（没查到不代表没到账）。
 * 轮完还没到账回 PENDING，界面说「到账稍有延迟」。登录失效照常往上抛。
 */
suspend fun pollRechargeStatus(
    fetch: suspend () -> RechargeStatus,
    tries: Int = 8,
    intervalMs: Long = 1500,
    delayFirst: Boolean = true,
    sleep: suspend (Long) -> Unit = { delay(it) },
): PollOutcome {
    repeat(tries) { i ->
        if (i > 0 || delayFirst) sleep(intervalMs)
        try {
            val s = fetch()
            if (s.paid || s.status == "paid") return PollOutcome.PAID
            if (s.status == "closed" || s.status == "expired") return PollOutcome.CLOSED
        } catch (e: CancellationException) { throw e } catch (e: Unauthorized) { throw e } catch (_: Exception) { }
    }
    return PollOutcome.PENDING
}

// ---- 一笔充值 ----

/** 一笔充值的结局，界面据此给一句话。 */
sealed interface RechargeResult {
    data object Paid : RechargeResult
    /** 这次没有新扣款：同金额上一笔（之前没确认到）现在确认到账了。 */
    data object PreviousPaid : RechargeResult
    /** 微信那边付了（或不确定），但查单还没到账：到账稍有延迟，稍后再看。 */
    data object Pending : RechargeResult
    data object Cancelled : RechargeResult
    data object NotInstalled : RechargeResult
    /** 服务端说这条通道没开：收起充值页，改弹说明。 */
    data object ChannelUnavailable : RechargeResult
    data object NothingPending : RechargeResult
    /** message 为 null 时用 recharge.failed。 */
    data class Failed(val message: String? = null) : RechargeResult
}

interface RechargeApi {
    suspend fun order(amountCents: Long, idempotencyKey: String): RechargeOrder
    suspend fun status(outTradeNo: String): RechargeStatus
}

class WxPayRecharge(
    private val api: RechargeApi,
    private val store: PendingRechargeStore,
    private val scope: String,
    /** 调起微信并等回调（cn 源集实现）。 */
    private val pay: suspend (AppPayParams) -> WxPayOutcome,
    private val sleep: suspend (Long) -> Unit = { delay(it) },
) {
    suspend fun purchase(amountCents: Long): RechargeResult = purchase(amountCents, retryOnConflict = true)

    private suspend fun purchase(amountCents: Long, retryOnConflict: Boolean): RechargeResult {
        // 同金额上回有一笔「付了但还没确认」的单子：先查一次。已到账就告诉用户「上一笔到了」，
        // 不把它说成这一次充值成功；关单了就作废换新键；还在途就沿用同一把键（不会变成两笔扣款）。
        store.current(scope)?.takeIf { it.amountCents == amountCents && it.outTradeNo != null }?.let { p ->
            when (pollRechargeStatus({ api.status(p.outTradeNo!!) }, tries = 1, delayFirst = false, sleep = sleep)) {
                PollOutcome.PAID -> { store.clear(scope); return RechargeResult.PreviousPaid }
                PollOutcome.CLOSED -> store.clear(scope)
                PollOutcome.PENDING -> Unit
            }
        }
        val key = store.takeKey(scope, amountCents)
        val order = try {
            api.order(amountCents, key)
        } catch (e: ApiError) {
            if (isChannelUnavailable(e)) return RechargeResult.ChannelUnavailable
            // 这把键的单子已经付过：不重新下单，拿服务端回的单号直接查单
            if (e.kind == EnvelopeKind.ALREADY_PAID && e.outTradeNo != null) {
                store.attach(scope, key, e.outTradeNo)
                val r = confirm(e.outTradeNo)
                return if (r == RechargeResult.Paid) RechargeResult.PreviousPaid else r
            }
            // 同一把键换了金额/类型：换新键重来一次，只重来一次，避免打转
            if (e.kind == EnvelopeKind.IDEMPOTENCY_CONFLICT && retryOnConflict) {
                store.clear(scope)
                return purchase(amountCents, retryOnConflict = false)
            }
            throw e
        }
        val params = order.appPayParams() ?: return RechargeResult.Failed()
        store.attach(scope, key, order.outTradeNo)
        return when (pay(params)) {
            // 取消与失败都不清幂等键：同一档再点一次复用同一把键，不会变成两笔单
            WxPayOutcome.CANCELLED -> RechargeResult.Cancelled
            WxPayOutcome.NOT_INSTALLED -> RechargeResult.NotInstalled
            WxPayOutcome.FAILED -> RechargeResult.Failed()
            WxPayOutcome.SUCCESS, WxPayOutcome.UNKNOWN -> confirm(order.outTradeNo)
        }
    }

    /**
     * 恢复：上次落盘的单子有单号就去查。[quick] = 进页面时的静默检查，只查一次不等待；
     * 用户点「查询未完成的支付」时按正常节奏轮询。
     */
    suspend fun resume(quick: Boolean): RechargeResult {
        val outTradeNo = store.current(scope)?.outTradeNo ?: return RechargeResult.NothingPending
        return confirm(outTradeNo, tries = if (quick) 1 else 8, delayFirst = !quick)
    }

    private suspend fun confirm(outTradeNo: String, tries: Int = 8, delayFirst: Boolean = true): RechargeResult =
        when (pollRechargeStatus({ api.status(outTradeNo) }, tries = tries, delayFirst = delayFirst, sleep = sleep)) {
            PollOutcome.PAID -> { store.clear(scope); RechargeResult.Paid }
            // 关单/过期：这把键的单子作废，下次换新键
            PollOutcome.CLOSED -> { store.clear(scope); RechargeResult.Failed() }
            PollOutcome.PENDING -> RechargeResult.Pending
        }
}

/** 调起微信的那一下。实现在 cn 源集（OpenSDK）；intl 源集给 null（国际版不带 OpenSDK）。 */
interface WxPayLauncher {
    fun installed(): Boolean
    /** sendReq 发出去了才回 true；回 true 之后等 [WxPayResults]。 */
    fun send(params: AppPayParams): Boolean
}
