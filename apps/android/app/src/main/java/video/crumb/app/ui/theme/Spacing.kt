// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.ui.theme

import androidx.compose.ui.unit.dp

/**
 * The one spacing scale (polish pass G7): 4, 8, 12, 16, 24.
 *
 * Screen gutter [l], row gap [s], tile gap [xs], card gap [m], section gap [xl].
 * Prefer these over ad hoc 2/6/10/14 dp literals.
 */
object Spacing {
    val xs = 4.dp
    val s = 8.dp
    val m = 12.dp
    val l = 16.dp
    val xl = 24.dp
}
