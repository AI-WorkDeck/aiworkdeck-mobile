package com.aiworkdeck.mobile.features.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalUriHandler
import com.aiworkdeck.mobile.BuildConfig
import com.aiworkdeck.mobile.design.Fonts
import com.aiworkdeck.mobile.design.Tk
import com.aiworkdeck.mobile.design.tr
import com.aiworkdeck.mobile.services.mobilePrivacyUrl

/** Shown before restoring a session or requesting device permissions. */
@Composable
fun PrivacyConsentScreen(onAccept: () -> Unit, onDecline: () -> Unit) {
    val uriHandler = LocalUriHandler.current
    Column(
        modifier = Modifier.fillMaxSize().background(Tk.L.bg).safeDrawingPadding()
            .verticalScroll(rememberScrollState()).padding(Tk.Sp.gutter),
        verticalArrangement = Arrangement.spacedBy(Tk.Sp.s6),
    ) {
        Text(tr("privacy.title"), style = Fonts.display(), color = Tk.L.fg)
        Text(tr("privacy.summary"), style = Fonts.body(), color = Tk.L.fg)
        TextButton(onClick = { uriHandler.openUri(mobilePrivacyUrl(BuildConfig.FLAVOR)) }) {
            Text(tr("privacy.policy"), color = Tk.L.accent)
        }
        Button(onClick = onAccept, modifier = Modifier.fillMaxWidth(), colors = ButtonDefaults.buttonColors(containerColor = Tk.L.accent)) { Text(tr("privacy.accept")) }
        TextButton(onClick = onDecline, modifier = Modifier.fillMaxWidth()) { Text(tr("privacy.decline"), color = Tk.L.accent) }
    }
}
