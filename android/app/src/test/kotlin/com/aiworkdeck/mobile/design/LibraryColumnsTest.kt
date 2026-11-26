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

    @Test fun projectListOnlyOnTallSplitWindows() {
        // Phone landscape (915 x 411dp) is Expanded width but stays list-free; tablets and unfolded screens get it.
        assertEquals(false, libraryProjectPane(layoutFor(915f, 411f), 411f))
        assertEquals(false, libraryProjectPane(layoutFor(411f, 915f), 915f))
        assertEquals(true, libraryProjectPane(layoutFor(1280f, 800f), 800f))
        assertEquals(false, libraryProjectPane(layoutFor(800f, 1280f), 1280f))
        assertEquals(true, libraryProjectPane(layoutFor(841f, 701f), 701f))
        assertEquals(false, libraryProjectPane(layoutFor(900f, 479f), 479f))
        assertEquals(true, libraryProjectPane(layoutFor(900f, 480f), 480f))
    }
}
