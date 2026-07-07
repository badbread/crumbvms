// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.di

import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext
import video.crumb.app.CrumbApp

/** Obtain the app-wide [AppContainer] from within a Composable. */
@Composable
fun appContainer(): AppContainer =
    (LocalContext.current.applicationContext as CrumbApp).container
