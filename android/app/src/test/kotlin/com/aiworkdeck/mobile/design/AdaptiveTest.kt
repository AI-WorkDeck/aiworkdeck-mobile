package com.aiworkdeck.mobile.design

import org.junit.Assert.assertEquals
import org.junit.Test

class AdaptiveTest {
    private fun l(w: Int, h: Int) = layoutFor(w.toFloat(), h.toFloat())

    @Test fun phonePortraitKeepsBottomBarAndSinglePane() {
        assertEquals(WindowLayout.Phone, l(411, 891))
        assertEquals(WindowLayout.Phone, l(360, 640))
    }

    @Test fun phoneLandscapeWideEnoughSplitsLikeToday() {
        // A phone on its side is wider than 840dp: rail plus split, as Queue/Files did at >= 700/720 in landscape.
        assertEquals(WindowLayout(navRail = true, splitPanes = true), l(891, 411))
    }

    @Test fun foldableInnerAndSmallTabletPortraitGetRailButOnePane() {
        assertEquals(WindowLayout(navRail = true, splitPanes = false), l(673, 841))
        assertEquals(WindowLayout(navRail = true, splitPanes = false), l(800, 1280))
    }

    @Test fun mediumLandscapeSplits() {
        assertEquals(WindowLayout(navRail = true, splitPanes = true), l(700, 500))
    }

    @Test fun expandedSplitsInBothOrientations() {
        assertEquals(WindowLayout(navRail = true, splitPanes = true), l(1280, 800))
        assertEquals(WindowLayout(navRail = true, splitPanes = true), l(840, 1200))
    }

    @Test fun boundaries() {
        assertEquals(false, l(599, 900).navRail)
        assertEquals(true, l(600, 900).navRail)
        assertEquals(false, l(839, 900).splitPanes)
        assertEquals(true, l(840, 900).splitPanes)
        // Medium but square: not landscape, so one pane.
        assertEquals(false, l(700, 700).splitPanes)
    }
}
