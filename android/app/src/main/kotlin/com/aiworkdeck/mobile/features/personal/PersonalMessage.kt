// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
package com.aiworkdeck.mobile.features.personal

import android.content.ClipData
import android.content.ClipboardManager
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import com.aiworkdeck.mobile.design.Fonts
import com.aiworkdeck.mobile.design.Tk
import com.aiworkdeck.mobile.design.tr

/** 一条对话。与 iOS 同：用户的话靠右、淡品牌色底；助理的回答整宽、带「AI 生成」标识，可选中、可复制。 */
@Composable
internal fun PersonalMessage(role: String, content: String) {
    val context = LocalContext.current
    if (role == "assistant") {
        val label = tr("personal.aiGenerated")
        val shown = stripEmoji(content)
        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(Tk.Sp.s1)) {
            Text(label, style = Fonts.nano(), color = Tk.L.fgMuted)
            SelectionContainer { Text(shown, style = Fonts.body().copy(lineHeight = 24.sp), color = Tk.L.fg) }
            Text(tr("personal.copyMessage"), style = Fonts.small(), color = Tk.L.accent,
                modifier = Modifier.heightIn(min = Tk.touchMin).clickable(role = Role.Button) {
                    context.getSystemService(ClipboardManager::class.java)
                        .setPrimaryClip(ClipData.newPlainText(label, "$label\n$shown"))
                }.wrapContentHeight())
        }
    } else {
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
            SelectionContainer {
                Text(content, style = Fonts.body(), color = Tk.L.fg,
                    modifier = Modifier.widthIn(max = 520.dp).clip(RoundedCornerShape(10.dp)).background(Tk.L.accentWash).padding(Tk.Sp.s3))
            }
        }
    }
}
