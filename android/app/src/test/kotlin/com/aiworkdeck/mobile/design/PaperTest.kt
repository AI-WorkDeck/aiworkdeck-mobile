package com.aiworkdeck.mobile.design

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.graphics.luminance
import com.aiworkdeck.contract.T
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Normal screens follow system dark mode via [Tk.Paper]; light must stay exactly today's tokens. */
class PaperTest {
    @Test fun dayIsTodaysLightTokens() {
        val d = Tk.Paper.Day
        assertEquals(Color(T.L.bg), d.bg)
        assertEquals(Color(T.L.sunken), d.sunken)
        assertEquals(Color(T.L.fg), d.fg)
        assertEquals(Color(T.L.fgMuted), d.fgMuted)
        assertEquals(Color(T.L.fgFaint), d.fgFaint)
        assertEquals(Color(T.L.rule), d.rule)
        assertEquals(Color(T.L.ruleStrong), d.ruleStrong)
        assertEquals(Color(T.L.accent), d.accent)
        assertEquals(Color(T.L.accentWash), d.accentWash)
        // PrimaryButton text was Tk.D.fg before this palette existed
        assertEquals(Color(T.D.fg), d.onAccent)
        assertEquals(d, Tk.Paper.of(night = false))
    }

    @Test fun nightUsesOnlyExistingDarkTokens() {
        val n = Tk.Paper.Night
        assertEquals(Color(T.D.bg), n.bg)
        assertEquals(Color(T.D.surface), n.sunken)
        assertEquals(Color(T.D.fg), n.fg)
        assertEquals(Color(T.D.fgMuted), n.fgMuted)
        assertEquals(Color(T.D.fgMuted), n.fgFaint)
        assertEquals(Color(T.D.rule), n.rule)
        assertEquals(Color(T.D.rule), n.ruleStrong)
        assertEquals(Color(T.S.arrivedOnDark), n.accent)
        assertEquals(Color(T.D.rule), n.accentWash)
        assertEquals(Color(T.D.bg), n.onAccent)
        assertEquals(n, Tk.Paper.of(night = true))
    }

    @Test fun nightTextPairsMeetAa() {
        val n = Tk.Paper.Night
        // accentWash is 10% white; it is drawn over the page, so judge it composited on bg
        val wash = n.accentWash.compositeOver(n.bg)
        val pairs = listOf(
            "fg/bg" to (n.fg to n.bg),
            "fgMuted/bg" to (n.fgMuted to n.bg),
            "fgFaint/bg" to (n.fgFaint to n.bg),
            "fg/sunken" to (n.fg to n.sunken),
            "fgMuted/sunken" to (n.fgMuted to n.sunken),
            "accent/bg" to (n.accent to n.bg),
            "accent/sunken" to (n.accent to n.sunken),
            "accent/accentWash" to (n.accent to wash),
            "fg/accentWash" to (n.fg to wash),
            "onAccent/accent" to (n.onAccent to n.accent),
            "waitingOnDark/bg" to (Tk.S.waitingOnDark to n.bg),
            "movingOnDark/bg" to (Tk.S.movingOnDark to n.bg),
            "arrivedOnDark/bg" to (Tk.S.arrivedOnDark to n.bg),
        )
        for ((name, pair) in pairs) {
            val ratio = contrast(pair.first, pair.second)
            assertTrue("$name is ${"%.2f".format(ratio)}:1", ratio >= 4.5)
        }
    }

    @Test fun dayTextPairsUnchangedAndAa() {
        val d = Tk.Paper.Day
        assertTrue(contrast(d.fg, d.bg) >= 4.5)
        assertTrue(contrast(d.fgMuted, d.bg) >= 4.5)
        assertTrue(contrast(d.accent, d.bg) >= 4.5)
        assertTrue(contrast(d.onAccent, d.accent) >= 4.5)
    }

    private fun contrast(a: Color, b: Color): Double {
        val la = a.luminance().toDouble()
        val lb = b.luminance().toDouble()
        return (maxOf(la, lb) + 0.05) / (minOf(la, lb) + 0.05)
    }
}
