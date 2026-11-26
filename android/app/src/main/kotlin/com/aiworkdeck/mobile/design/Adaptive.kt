package com.aiworkdeck.mobile.design

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * Window layout from the Material window size classes (width Compact < 600dp ≤ Medium < 840dp ≤ Expanded).
 * Measured from the window's root constraints in MainActivity, so split screen and an unfolded foldable
 * get the size of the window they actually have, not of the device.
 *
 * - [navRail]: Medium or Expanded width. The tab bar moves to a rail at the start edge.
 * - [splitPanes]: Expanded, or Medium in landscape. List and detail sit side by side (iOS: regular
 *   size class and ≥ 700pt). Medium covers today's 700/720dp landscape split on small tablets.
 */
data class WindowLayout(val navRail: Boolean, val splitPanes: Boolean) {
    companion object {
        val Phone = WindowLayout(navRail = false, splitPanes = false)
    }
}

const val MEDIUM_WIDTH_DP = 600
const val EXPANDED_WIDTH_DP = 840

/** Longest comfortable line for forms and settings on a wide window. */
val ReadableWidth: Dp = 640.dp

fun layoutFor(widthDp: Float, heightDp: Float): WindowLayout {
    val medium = widthDp >= MEDIUM_WIDTH_DP
    val expanded = widthDp >= EXPANDED_WIDTH_DP
    return WindowLayout(navRail = medium, splitPanes = expanded || (medium && widthDp > heightDp))
}

/**
 * Library grid columns: the user's 2/3/4 choice is a density step, scaled by how many 400dp bands the pane spans,
 * so tiles stay about phone-sized on a tablet instead of four huge ones.
 */
fun libraryColumns(choice: Int, paneWidthDp: Float): Int = choice * maxOf(1, (paneWidthDp / 400f).toInt())

/** Width of the project list beside the Library grid on [WindowLayout.splitPanes]. */
val LibraryProjectPaneWidth: Dp = 280.dp

/**
 * The Library's project list needs a split layout **and** a tall window: a phone in landscape is Expanded width but
 * is used for capture, and a 280dp list there would eat the grid (CEO, 11-26). Same 480dp line as the capture screen.
 */
fun libraryProjectPane(layout: WindowLayout, heightDp: Float): Boolean = layout.splitPanes && heightDp >= 480f

/** Phone layout by default: previews and screens outside the shell keep today's behaviour. */
val LocalWindowLayout = staticCompositionLocalOf { WindowLayout.Phone }

/**
 * Caps the content at [ReadableWidth] and centres it. Put it after `fillMaxSize()`/`fillMaxWidth()`, `background(...)`
 * and the insets padding, so the background still fills the window (without a fill before it, the content is
 * capped but stays at the start edge). On a phone (narrower than [ReadableWidth]) nothing changes.
 */
fun Modifier.readableWidth(): Modifier =
    wrapContentWidth(Alignment.CenterHorizontally).widthIn(max = ReadableWidth).fillMaxWidth()
