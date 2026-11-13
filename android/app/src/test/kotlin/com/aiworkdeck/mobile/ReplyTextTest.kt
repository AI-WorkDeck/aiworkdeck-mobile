// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
package com.aiworkdeck.mobile

import com.aiworkdeck.mobile.features.personal.EmojiProps
import com.aiworkdeck.mobile.features.personal.stripEmoji
import org.junit.Test
import org.junit.Assert.assertEquals

class ReplyTextTest {
    // android.icu is not available on the JVM; the JDK's own Unicode tables stand in for the same properties.
    private val jdk = object : EmojiProps {
        override fun presentation(cp: Int) = Character.isEmojiPresentation(cp)
        override fun pictographic(cp: Int) = Character.isExtendedPictographic(cp)
    }

    @Test fun stripsEmojiAndKeepsPlainSymbols() {
        val keep = "© 2026 甲方 ↔ 乙方 ▶ 见第 3 条 ™ ® ✓ ★ § ¶ →"
        val cases = listOf(
            "### ✅ 第一条 — 引用正确" to "### 第一条 — 引用正确",
            "| 一 | ❌ 错误 |" to "| 一 | 错误 |",
            "**⚠️ One problem:** x" to "**One problem:** x",
            "已完成🎉。" to "已完成。",
            "👨‍⚖️ 法官" to "法官",
            "👍🏻 好" to "好",
            "1️⃣ 第一步" to "1 第一步",
            keep to keep,
        )
        for ((input, expected) in cases) assertEquals(input, expected, stripEmoji(input, jdk))
    }
}
