// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app

import android.app.Application
import video.crumb.app.data.CacheJanitor
import video.crumb.app.di.AppContainer
import kotlin.concurrent.thread

/** Application entry point — owns the singleton [AppContainer]. */
class CrumbApp : Application() {
    lateinit var container: AppContainer
        private set

    override fun onCreate() {
        super.onCreate()
        container = AppContainer(this)
        // Bounded, best-effort prune of the app-private report/export cache dirs so
        // they don't grow forever (#147-12). Off the main thread; never fatal.
        thread(isDaemon = true, name = "cache-janitor") {
            CacheJanitor.prune(applicationContext)
        }
    }
}
