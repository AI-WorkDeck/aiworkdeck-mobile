// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
package com.aiworkdeck.mobile.features.personal

import android.content.ClipData
import android.content.ClipboardManager
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.aiworkdeck.mobile.design.Tk
import com.aiworkdeck.mobile.design.tr

@Composable
internal fun PersonalMessage(role: String, content: String) {
    val context = LocalContext.current
    if (role == "assistant") {
        val label = tr("personal.aiGenerated")
        Column(Modifier.fillMaxWidth().padding(12.dp)) {
            Text(label, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Medium, color = Tk.L.fg)
            val shown = stripEmoji(content)
            Text(shown, style = MaterialTheme.typography.bodyLarge, color = Tk.L.fg)
            TextButton(onClick = {
                context.getSystemService(ClipboardManager::class.java)
                    .setPrimaryClip(ClipData.newPlainText(label, "$label\n$shown"))
            }) { Text(tr("personal.copyMessage")) }
        }
    } else {
        SelectionContainer { Text(content, color = Tk.L.fg, modifier = Modifier.fillMaxWidth().padding(12.dp)) }
    }
}
