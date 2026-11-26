// SPDX-FileCopyrightText: 2026 北京公富信息技术有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
package com.aiworkdeck.mobile.design

import org.junit.Assert.assertEquals
import org.junit.Test

class LibraryColumnsTest {
    @Test fun choiceIsADensityStepScaledByPaneWidth() {
        val widths = listOf(360f, 600f, 900f, 1280f)
        assertEquals(listOf(2, 2, 4, 6), widths.map { libraryColumns(2, it) })
        assertEquals(listOf(3, 3, 6, 9), widths.map { libraryColumns(3, it) })
        assertEquals(listOf(4, 4, 8, 12), widths.map { libraryColumns(4, it) })
    }

    @Test fun phoneWidthsKeepTheChoiceAsIs() {
        for (c in 2..4) for (w in listOf(320f, 399f, 411f, 599f)) assertEquals(c, libraryColumns(c, w))
    }
}
