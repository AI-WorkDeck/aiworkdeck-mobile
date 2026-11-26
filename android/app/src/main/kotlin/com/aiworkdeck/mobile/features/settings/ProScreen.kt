package com.aiworkdeck.mobile.features.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
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
import com.aiworkdeck.mobile.design.Fonts
import com.aiworkdeck.mobile.design.Hairline
import com.aiworkdeck.mobile.design.LightStatusBar
import com.aiworkdeck.mobile.design.PrimaryButton
import com.aiworkdeck.mobile.design.Tk
import com.aiworkdeck.mobile.design.WorkdeckTheme
import com.aiworkdeck.mobile.design.tr
import com.aiworkdeck.mobile.features.queue.TextAction
import com.aiworkdeck.mobile.features.queue.noRipple
import com.aiworkdeck.mobile.services.ApiError
import com.aiworkdeck.mobile.services.EnvelopeKind
import com.aiworkdeck.mobile.services.ProQuote
import com.aiworkdeck.mobile.services.RechargeResult
import com.aiworkdeck.mobile.services.ServiceLocator
import com.aiworkdeck.mobile.services.WxPayOutcome
import com.aiworkdeck.mobile.services.WxPayRecharge
import com.aiworkdeck.mobile.services.WxPayResults
import com.aiworkdeck.mobile.services.awaitWxPayResult
import com.aiworkdeck.mobile.services.proRechargeApi
import com.aiworkdeck.mobile.services.userFacingMessage
import com.aiworkdeck.mobile.services.wxPayLauncher
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.launch

/** Pro is sold only on the mainland site, always in RMB. */
private const val PRO_CURRENCY = "CNY"

/** Same pause as the top-up sheet before closing on success. */
private const val PRO_CLOSE_DELAY_MS = 900L

/** Why the quote says Pro can't be bought here. Unknown reasons read as "not open". */
internal fun proUnavailableKey(reason: String?): String = when (reason) {
    "appstore_subscription_active" -> "subscription.wxpay.appleActive"
    "not_connected" -> "recharge.openHint"
    else -> "subscription.store.closed"
}

/** The one line shown after a Pro purchase or a resume check. */
internal fun proHint(result: RechargeResult): String = when (result) {
    RechargeResult.Paid -> tr("subscription.wxpay.paid")
    RechargeResult.PreviousPaid -> tr("recharge.wxpay.previousArrived")
    RechargeResult.Pending -> tr("recharge.pendingLong")
    RechargeResult.Cancelled -> tr("recharge.cancelled")
    RechargeResult.NotInstalled -> tr("recharge.wxpay.notInstalled")
    RechargeResult.NothingPending -> tr("recharge.wxpay.resumeNone")
    RechargeResult.ChannelUnavailable -> tr("subscription.store.closed")
    is RechargeResult.Failed -> result.message ?: tr("recharge.failed")
}

/**
 * Personal Pro with WeChat APP pay (POLISH M3), mainland edition only. The server quotes SKU and price; each
 * payment buys 30 days and never renews. Payment, idempotency and confirmation are [WxPayRecharge] as for top-up,
 * with its own pending-order slot (Prefs.pendingPro).
 *
 * [onClose] gets whether a payment was confirmed, so the caller reloads status.
 */
@Composable
fun ProScreen(onClose: (paid: Boolean) -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var quote by remember { mutableStateOf<ProQuote?>(null) }
    var quoteError by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var hint by remember { mutableStateOf("") }
    var paid by remember { mutableStateOf(false) }

    // Fired on return from WeChat, so a missing SDK callback doesn't spin forever (see awaitWxPayResult)
    val resumed = remember { MutableSharedFlow<Unit>(extraBufferCapacity = 1) }
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_RESUME) resumed.tryEmit(Unit) }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    val backend = remember { ServiceLocator.backend }
    val accountScope = remember { backend.personalAccountScope().orEmpty() }
    // Status checks don't depend on the SKU, so resume works before (or without) a quote.
    fun flow(skuId: String) = WxPayRecharge(
        api = proRechargeApi(backend, skuId),
        store = ServiceLocator.prefs.pendingPro,
        scope = accountScope,
        pay = pay@{ params ->
            val launcher = wxPayLauncher(context) ?: return@pay WxPayOutcome.FAILED
            if (!launcher.installed()) return@pay WxPayOutcome.NOT_INSTALLED
            WxPayResults.reset()
            if (!launcher.send(params)) return@pay WxPayOutcome.FAILED
            awaitWxPayResult(WxPayResults.results, resumed)
        },
    )

    suspend fun loadQuote() {
        try { quote = backend.billingProQuote(); quoteError = null }
        catch (e: CancellationException) { throw e }
        catch (e: Exception) { quoteError = userFacingMessage(e, tr("recharge.failed")) }
    }

    fun settle(result: RechargeResult) {
        hint = proHint(result)
        if (result == RechargeResult.ChannelUnavailable) quote = ProQuote(available = false, reason = "disabled")
        if (result == RechargeResult.Paid || result == RechargeResult.PreviousPaid) {
            paid = true
            scope.launch { delay(PRO_CLOSE_DELAY_MS); onClose(true) }
        }
    }

    fun run(block: suspend () -> RechargeResult) {
        if (busy) return
        busy = true
        hint = tr("recharge.paying")
        scope.launch {
            try { settle(block()) }
            catch (e: CancellationException) { throw e }
            catch (e: Exception) {
                // Server messages are already user-facing (LangText); branch on kind only.
                hint = userFacingMessage(e, tr("recharge.failed"))
                // Price changed or Apple Pro became active: re-quote so the sheet shows what is true now
                if (e is ApiError && e.kind == EnvelopeKind.REJECTED) loadQuote()
            }
            finally { busy = false }
        }
    }

    LaunchedEffect(Unit) {
        loadQuote()
        // Quietly check a payment that was never confirmed (killed / offline); only speak if it arrived
        try {
            if (flow("").resume(quick = true) == RechargeResult.Paid) settle(RechargeResult.PreviousPaid)
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
                    Text(tr("subscription.wxpay.title"), style = Fonts.heading(), color = Tk.L.fg)
                }
                Hairline(color = Tk.L.rule)

                Column(
                    Modifier.fillMaxSize().verticalScroll(rememberScrollState())
                        .padding(horizontal = Tk.Sp.gutter).padding(bottom = Tk.Sp.s16),
                    verticalArrangement = Arrangement.spacedBy(Tk.Sp.s3),
                ) {
                    val q = quote
                    val skuId = q?.skuId
                    if (q == null) {
                        if (quoteError != null) {
                            Text(quoteError!!, style = Fonts.small(), color = Tk.L.fgMuted, modifier = Modifier.padding(top = Tk.Sp.s6))
                            TextAction(tr("project.retry"), color = Tk.L.accent) { scope.launch { loadQuote() } }
                        } else {
                            LinearProgressIndicator(Modifier.fillMaxWidth().padding(top = Tk.Sp.s6), color = Tk.L.accent, trackColor = Tk.L.rule)
                        }
                    } else if (!q.available || skuId.isNullOrBlank() || q.amountCents <= 0) {
                        Text(tr(proUnavailableKey(q.reason)), style = Fonts.body(), color = Tk.L.fg, modifier = Modifier.padding(top = Tk.Sp.s6))
                    } else {
                        Text(
                            tr("subscription.store.price", mapOf("price" to formatMoney(q.amountCents, PRO_CURRENCY))),
                            style = Fonts.title(), color = Tk.L.fg, modifier = Modifier.padding(top = Tk.Sp.s6),
                        )
                        if (q.introEligible && q.introRemainingMonths > 0) Text(
                            tr("subscription.wxpay.intro", mapOf(
                                "months" to q.introRemainingMonths,
                                "price" to formatMoney(q.amountCents, PRO_CURRENCY),
                                "standard" to formatMoney(q.standardAmountCents, PRO_CURRENCY),
                            )),
                            style = Fonts.small(), color = Tk.L.fgMuted,
                        )
                        Text(tr("subscription.wxpay.term", mapOf("days" to q.days)), style = Fonts.small(), color = Tk.L.fgMuted)
                        PrimaryButton(
                            tr("subscription.wxpay.pay", mapOf("price" to formatMoney(q.amountCents, PRO_CURRENCY))),
                            onClick = { run { flow(skuId).purchase(q.amountCents) } },
                            enabled = !busy && !paid, modifier = Modifier.padding(top = Tk.Sp.s4),
                        )
                    }
                    if (busy) LinearProgressIndicator(Modifier.fillMaxWidth(), color = Tk.L.accent, trackColor = Tk.L.rule)
                    if (hint.isNotEmpty()) Text(hint, style = Fonts.small(), color = Tk.L.fgMuted)

                    Hairline(color = Tk.L.rule, modifier = Modifier.padding(top = Tk.Sp.s4))
                    TextAction(tr("recharge.wxpay.resume"), color = if (busy) Tk.L.fgFaint else Tk.L.accent) {
                        run { flow("").resume(quick = false) }
                    }
                }
            }
        }
    }
}
