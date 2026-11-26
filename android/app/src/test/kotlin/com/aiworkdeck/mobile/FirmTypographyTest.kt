// SPDX-FileCopyrightText: 2026 北京公富信息技术有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
package com.aiworkdeck.mobile

import java.io.File
import org.junit.Test
import org.junit.Assert.assertTrue

/**
 * Lane X review (X48): the firm review screens show mixed-case text (times, status chips, speaker
 * names, firm names). Fonts.nano() is the uppercase eyebrow style with 0.14em tracking, and
 * Tk.L.fgFaint (~2.5:1) is decoration-only, so neither may style that text.
 */
class FirmTypographyTest {
    private val dir = File("src/main/kotlin/com/aiworkdeck/mobile/features/firm")

    @Test
    fun firmScreensDoNotUseTheEyebrowStyleOrFaintTextColour() {
        val offenders = dir.listFiles { f -> f.name.endsWith(".kt") }!!.flatMap { f ->
            f.readLines().mapIndexedNotNull { i, line ->
                val text = line.contains("Text(")
                if (text && (line.contains("Fonts.nano()") || line.contains("Tk.L.fgFaint"))) "${f.name}:${i + 1}" else null
            }
        }
        assertTrue("eyebrow style or faint colour on firm text: $offenders", offenders.isEmpty())
    }
}
