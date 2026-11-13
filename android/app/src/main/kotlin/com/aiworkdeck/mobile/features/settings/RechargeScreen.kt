package com.aiworkdeck.mobile.features.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.aiworkdeck.contract.ContractProducts
import com.aiworkdeck.mobile.design.Fonts
import com.aiworkdeck.mobile.design.Hairline
import com.aiworkdeck.mobile.design.LightStatusBar
import com.aiworkdeck.mobile.design.PrimaryButton
import com.aiworkdeck.mobile.design.Tk
import com.aiworkdeck.mobile.design.WorkdeckTheme
import com.aiworkdeck.mobile.design.tr
import com.aiworkdeck.mobile.features.auth.Eyebrow
import com.aiworkdeck.mobile.features.queue.TextAction
import com.aiworkdeck.mobile.features.queue.noRipple
import com.aiworkdeck.mobile.services.RechargeApi
import com.aiworkdeck.mobile.services.RechargeResult
import com.aiworkdeck.mobile.services.ServiceLocator
import com.aiworkdeck.mobile.services.WxPayOutcome
import com.aiworkdeck.mobile.services.WxPayRecharge
import com.aiworkdeck.mobile.services.WxPayResults
import com.aiworkdeck.mobile.services.awaitWxPayResult
import com.aiworkdeck.mobile.services.userFacingMessage
import com.aiworkdeck.mobile.services.wxPayLauncher
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.launch

/** 微信 APP 支付只在大陆站，档位一律人民币。 */
private const val CURRENCY = "CNY"

/** 成功那句话停留多久再自动关页（设置页随即重拉余额），与小程序同。 */
private const val CLOSE_DELAY_MS = 900L

/** 一笔充值的结局对应的那句话。 */
internal fun rechargeHint(result: RechargeResult): String = when (result) {
    RechargeResult.Paid -> tr("recharge.success")
    RechargeResult.PreviousPaid -> tr("recharge.wxpay.previousArrived")
    RechargeResult.Pending -> tr("recharge.pendingLong")
    RechargeResult.Cancelled -> tr("recharge.cancelled")
    RechargeResult.NotInstalled -> tr("recharge.wxpay.notInstalled")
    RechargeResult.NothingPending -> tr("recharge.wxpay.resumeNone")
    RechargeResult.ChannelUnavailable -> tr("recharge.external.body")
    is RechargeResult.Failed -> result.message ?: tr("recharge.failed")
}

/**
 * 充值页 —— 微信支付 APP 支付（dev-board#428），镜像 iOS `RechargeView`：选档、付款、确认到账、
 * 成功/失败一句话、恢复未完成的支付。档位只来自契约（contract/products.json 的 wxpayApp 段）。
 *
 * [onClose] 的参数 = 这次有没有确认到账（设置页据此重拉余额与后付费）。
 * [onChannelUnavailable]：服务端说本部署没开这条通道，设置页收起本页改弹说明。
 */
@Composable
fun RechargeScreen(onClose: (paid: Boolean) -> Unit, onChannelUnavailable: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val tiers = ContractProducts.wxpayApp
    var selected by remember { mutableStateOf(tiers.getOrNull(1) ?: tiers.first()) }
    var busy by remember { mutableStateOf(false) }
    var hint by remember { mutableStateOf("") }
    var paid by remember { mutableStateOf(false) }

    // 从微信切回来时发一下：微信没回调也不至于一直转圈（见 awaitWxPayResult）
    val resumed = remember { MutableSharedFlow<Unit>(extraBufferCapacity = 1) }
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_RESUME) resumed.tryEmit(Unit) }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    val flow = remember {
        val backend = ServiceLocator.backend
        WxPayRecharge(
            api = object : RechargeApi {
                override suspend fun order(amountCents: Long, idempotencyKey: String) = backend.billingRecharge(amountCents, idempotencyKey)
                override suspend fun status(outTradeNo: String) = backend.billingRechargeStatus(outTradeNo)
            },
            store = ServiceLocator.prefs.pendingRecharge,
            scope = backend.personalAccountScope().orEmpty(),
            pay = pay@{ params ->
                val launcher = wxPayLauncher(context) ?: return@pay WxPayOutcome.FAILED
                if (!launcher.installed()) return@pay WxPayOutcome.NOT_INSTALLED
                WxPayResults.reset()
                if (!launcher.send(params)) return@pay WxPayOutcome.FAILED
                awaitWxPayResult(WxPayResults.results, resumed)
            },
        )
    }

    fun settle(result: RechargeResult) {
        if (result == RechargeResult.ChannelUnavailable) { onChannelUnavailable(); return }
        hint = rechargeHint(result)
        if (result == RechargeResult.Paid || result == RechargeResult.PreviousPaid) {
            paid = true
            scope.launch { delay(CLOSE_DELAY_MS); onClose(true) }
        }
    }

    fun run(block: suspend () -> RechargeResult) {
        if (busy) return
        busy = true
        hint = tr("recharge.paying")
        scope.launch {
            try { settle(block()) }
            catch (e: CancellationException) { throw e }
            // 服务端 message 经 LangText 已是可读话术，原样展示；不按措辞分支
            catch (e: Exception) { hint = userFacingMessage(e, tr("recharge.failed")) }
            finally { busy = false }
        }
    }

    // 进页面静默查一次上回没确认的单子（付完被杀 / 断网）：到账了就告诉用户，没到账不打扰
    LaunchedEffect(Unit) {
        try {
            val r = flow.resume(quick = true)
            if (r == RechargeResult.Paid) settle(RechargeResult.PreviousPaid)
        } catch (e: CancellationException) { throw e } catch (_: Exception) { }
    }

    Dialog(onDismissRequest = { onClose(paid) }, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        LightStatusBar()
        WorkdeckTheme(dark = false) {
            Column(Modifier.fillMaxSize().background(Tk.L.bg).safeDrawingPadding()) {
                Row(
                    Modifier.fillMaxWidth().padding(start = Tk.Sp.s2, end = Tk.Sp.gutter, bottom = Tk.Sp.s2),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s2),
                ) {
                    Box(
                        Modifier.size(Tk.touchMin).noRipple { onClose(paid) }.semantics { contentDescription = tr("common.close") },
                        contentAlignment = Alignment.Center,
                    ) { Text("✕", style = Fonts.body(), color = Tk.L.fg) }
                    Text(tr("recharge.title"), style = Fonts.heading(), color = Tk.L.fg)
                }
                Hairline(color = Tk.L.rule)

                Column(
                    Modifier.fillMaxSize().verticalScroll(rememberScrollState())
                        .padding(horizontal = Tk.Sp.gutter).padding(bottom = Tk.Sp.s16),
                    verticalArrangement = Arrangement.spacedBy(Tk.Sp.s3),
                ) {
                    Eyebrow(tr("recharge.pick"), Modifier.padding(top = Tk.Sp.s6))
                    for (cents in tiers) {
                        val on = cents == selected
                        Row(
                            Modifier.fillMaxWidth().heightIn(min = Tk.touchMin).noRipple { if (!busy) selected = cents },
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                tr("recharge.tier", mapOf("amount" to formatMoney(cents, CURRENCY))),
                                style = Fonts.body(), color = if (on) Tk.L.accent else Tk.L.fg, modifier = Modifier.weight(1f),
                            )
                            if (on) Text("✓", style = Fonts.body(), color = Tk.L.accent)
                        }
                        Hairline(color = Tk.L.rule)
                    }

                    PrimaryButton(tr("recharge.pay"), onClick = { run { flow.purchase(selected) } },
                        enabled = !busy && !paid, modifier = Modifier.padding(top = Tk.Sp.s4))
                    if (busy) LinearProgressIndicator(Modifier.fillMaxWidth(), color = Tk.L.accent, trackColor = Tk.L.rule)
                    if (hint.isNotEmpty()) Text(hint, style = Fonts.small(), color = Tk.L.fgMuted)

                    Hairline(color = Tk.L.rule, modifier = Modifier.padding(top = Tk.Sp.s4))
                    // 付完没确认到（被杀、断网、微信没回调）的单子：用户手上的那根绳子，对齐 iOS「恢复未完成的购买」
                    TextAction(tr("recharge.wxpay.resume"), color = if (busy) Tk.L.fgFaint else Tk.L.accent) {
                        run { flow.resume(quick = false) }
                    }
                }
            }
        }
    }
}
