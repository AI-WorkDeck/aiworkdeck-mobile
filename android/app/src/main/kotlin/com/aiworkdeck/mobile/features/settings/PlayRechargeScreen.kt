// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
package com.aiworkdeck.mobile.features.settings

import android.app.Activity
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
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
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
import com.aiworkdeck.mobile.design.Fonts
import com.aiworkdeck.mobile.design.Hairline
import com.aiworkdeck.mobile.design.LightStatusBar
import com.aiworkdeck.mobile.design.Tk
import com.aiworkdeck.mobile.design.WorkdeckTheme
import com.aiworkdeck.mobile.design.tr
import com.aiworkdeck.mobile.features.auth.Eyebrow
import com.aiworkdeck.mobile.features.queue.TextAction
import com.aiworkdeck.mobile.features.queue.noRipple
import com.aiworkdeck.mobile.services.ApiError
import com.aiworkdeck.mobile.services.PlayPurchaseOutcome
import com.aiworkdeck.mobile.services.PlayTier
import com.aiworkdeck.mobile.services.ServiceLocator
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/** Google Play 消耗型内购充值页（intl flavor，dev-board#665）。 */
@Composable
fun PlayRechargeScreen(onClose: () -> Unit) {
    val activity = LocalContext.current as? Activity
    val scope = rememberCoroutineScope()
    val coordinator = remember { ServiceLocator.playRecharge }
    val accountScope = remember { ServiceLocator.backend.personalAccountScope() }

    var tiers by remember { mutableStateOf<List<PlayTier>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var storeUnavailable by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var hint by remember { mutableStateOf("") }

    LaunchedEffect(Unit) {
        try {
            val loaded = coordinator.loadTiers()
            tiers = loaded
            storeUnavailable = loaded.isEmpty()
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            storeUnavailable = true
        } finally {
            loading = false
        }
    }

    LightStatusBar()
    WorkdeckTheme(dark = false) {
        Column(Modifier.fillMaxSize().background(Tk.L.bg).safeDrawingPadding()) {
            Column {
                Row(
                    Modifier.fillMaxWidth().padding(start = Tk.Sp.s2, end = Tk.Sp.gutter, bottom = Tk.Sp.s2),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s2),
                ) {
                    Box(
                        Modifier.size(Tk.touchMin).noRipple { if (!busy) onClose() }
                            .semantics { contentDescription = tr("common.close") },
                        contentAlignment = Alignment.Center,
                    ) { Text("✕", style = Fonts.body(), color = Tk.L.fg) }
                    Text(tr("recharge.title"), style = Fonts.heading(), color = Tk.L.fg)
                }
                Hairline(color = Tk.L.rule)
            }

            Column(
                Modifier.fillMaxSize().verticalScroll(rememberScrollState())
                    .padding(horizontal = Tk.Sp.gutter).padding(bottom = Tk.Sp.s16),
                verticalArrangement = Arrangement.spacedBy(Tk.Sp.s3),
            ) {
                Eyebrow(tr("recharge.pick"), Modifier.padding(top = Tk.Sp.s6))

                when {
                    loading -> Text(tr("recharge.ios.priceLoading"), style = Fonts.small(), color = Tk.L.fgFaint)
                    storeUnavailable || tiers.isEmpty() -> Text(
                        tr("recharge.play.storeUnavailable"),
                        style = Fonts.small(),
                        color = Tk.L.fgFaint,
                    )
                    else -> {
                        for (tier in tiers) {
                            Row(
                                Modifier.fillMaxWidth().heightIn(min = Tk.touchMin).noRipple {
                                    if (busy || activity == null) return@noRipple
                                    busy = true
                                    hint = tr("recharge.ios.pending")
                                    scope.launch {
                                        try {
                                            hint = when (coordinator.purchase(activity, tier, accountScope)) {
                                                is PlayPurchaseOutcome.Paid -> tr("recharge.success")
                                                PlayPurchaseOutcome.Cancelled -> tr("recharge.cancelled")
                                                PlayPurchaseOutcome.PendingLong -> tr("recharge.pendingLong")
                                                PlayPurchaseOutcome.Failed -> tr("recharge.failed")
                                            }
                                        } catch (e: CancellationException) {
                                            throw e
                                        } catch (e: ApiError) {
                                            hint = e.message ?: tr("recharge.failed")
                                        } catch (_: Exception) {
                                            hint = tr("recharge.failed")
                                        } finally {
                                            busy = false
                                        }
                                    }
                                },
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.SpaceBetween,
                            ) {
                                Text(
                                    tr("recharge.tier", mapOf("amount" to tier.formattedPrice)),
                                    style = Fonts.body(),
                                    color = if (busy) Tk.L.fgMuted else Tk.L.fg,
                                )
                                Text(
                                    tr("recharge.entry"),
                                    style = Fonts.small(),
                                    color = if (busy) Tk.L.fgFaint else Tk.L.accent,
                                )
                            }
                        }
                    }
                }

                if (hint.isNotEmpty()) {
                    Text(
                        hint,
                        style = Fonts.nano(),
                        color = Tk.L.fgFaint,
                        modifier = Modifier.padding(top = Tk.Sp.s2),
                    )
                }

                Hairline(color = Tk.L.rule, modifier = Modifier.padding(vertical = Tk.Sp.s4))

                TextAction(tr("recharge.ios.restore"), color = if (busy) Tk.L.fgFaint else Tk.L.accent) {
                    if (busy) return@TextAction
                    busy = true
                    hint = tr("recharge.ios.pending")
                    scope.launch {
                        try {
                            val landed = coordinator.replayUnconsumed(accountScope)
                            hint = if (landed > 0) tr("recharge.success") else tr("recharge.ios.restoreNone")
                        } catch (e: CancellationException) {
                            throw e
                        } catch (_: Exception) {
                            hint = tr("recharge.failed")
                        } finally {
                            busy = false
                        }
                    }
                }
            }
        }
    }
}
