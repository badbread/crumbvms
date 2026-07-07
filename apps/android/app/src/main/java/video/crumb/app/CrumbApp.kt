// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app

import android.app.Application
import video.crumb.app.di.AppContainer

/** Application entry point — owns the singleton [AppContainer]. */
class CrumbApp : Application() {
    lateinit var container: AppContainer
        private set

    override fun onCreate() {
        super.onCreate()
        container = AppContainer(this)
    }
}
