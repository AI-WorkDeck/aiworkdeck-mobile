// SPDX-FileCopyrightText: 2026 北京公富信息技术有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
package com.aiworkdeck.mobile.services.firm

import com.aiworkdeck.mobile.BuildConfig
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.net.URI

/**
 * Debug builds only: run the firm review journeys against a LOCAL copy of the portal server (AIWorkDeckAdmin/ai-firm
 * server/ with synthetic matters), like the iOS FirmUITestSeed. Combined with screenshot mode (seeded sign-in):
 *
 *   adb shell am start -n com.aiworkdeck.mobile/com.aiworkdeck.mobile.MainActivity \
 *     --ez awdScreenshot true --es awdFirmPortalBase http://10.0.2.2:8787 [--es awdScreen firm]
 *
 * Then join with an allowlisted link (e.g. aifirm.aiworkdeck.com/all) and the local server's trial code: requests
 * keep the portal path but go to the local base, with a synthetic session; nothing reaches production.
 */
object FirmSeed {
    const val EXTRA_BASE = "awdFirmPortalBase"
    const val SESSION = "seed-session"
    const val USER_ID = 1L

    /** The local portal base from the launch extra, or null (release builds never seed). */
    fun base(extra: String?, debug: Boolean = BuildConfig.DEBUG): okhttp3.HttpUrl? =
        if (!debug || extra.isNullOrBlank()) null else extra.toHttpUrlOrNull()

    fun portal(base: okhttp3.HttpUrl, trials: FirmTrialStore, settings: FirmSettings): FirmPortal {
        FirmPortalLink.debugBase = URI(base.toString())
        return FirmPortal(trials, settings, identity = { base.toString() to SESSION }, verifiedUserId = { USER_ID },
            transport = OkHttpFirmTransport(), baseOverride = base)
    }
}
