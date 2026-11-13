// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
package com.aiworkdeck.mobile.features.personal

import android.icu.lang.UCharacter
import android.icu.lang.UProperty

/** Unicode emoji properties; injectable because android.icu is unavailable in JVM unit tests. */
internal interface EmojiProps {
    fun presentation(cp: Int): Boolean
    fun pictographic(cp: Int): Boolean
}

internal object IcuEmojiProps : EmojiProps {
    override fun presentation(cp: Int) = UCharacter.hasBinaryProperty(cp, UProperty.EMOJI_PRESENTATION)
    override fun pictographic(cp: Int) = UCharacter.hasBinaryProperty(cp, UProperty.EXTENDED_PICTOGRAPHIC)
}

/**
 * Display-side backstop: strip emoji from assistant replies (same rule as desktop aiworkdeck#1539 stripEmoji.js).
 * Strips Emoji_Presentation chars, FE0F-qualified pictographs and the four dingbats, with skin tones, ZWJ
 * sequences and trailing spaces/tabs; keycaps keep their digit.
 */
internal fun stripEmoji(text: String, props: EmojiProps = IcuEmojiProps): String {
    val cps = text.codePoints().toArray()
    val out = StringBuilder(text.length)
    fun isStart(i: Int): Boolean {
        val c = cps[i]
        return props.presentation(c) || (props.pictographic(c) && cps.getOrNull(i + 1) == 0xFE0F) ||
            c == 0x26A0 || c == 0x2714 || c == 0x2716 || c == 0x2611
    }
    var i = 0
    while (i < cps.size) {
        val c = cps[i]
        if (c == 0xFE0F && cps.getOrNull(i + 1) == 0x20E3) { i += 2; continue }
        if (c == 0x20E3) { i++; continue }
        if (!isStart(i)) { out.appendCodePoint(c); i++; continue }
        i++
        if (cps.getOrNull(i)?.let { it in 0x1F3FB..0x1F3FF } == true) i++
        if (cps.getOrNull(i) == 0xFE0F) i++
        while (cps.getOrNull(i) == 0x200D && cps.getOrNull(i + 1)?.let { props.presentation(it) || props.pictographic(it) } == true) {
            i += 2
            if (cps.getOrNull(i) == 0xFE0F) i++
        }
        while (cps.getOrNull(i) == 0x20 || cps.getOrNull(i) == 0x09) i++
    }
    return out.toString()
}
