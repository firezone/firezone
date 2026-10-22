// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core

import android.app.Activity
import android.net.Uri
import dev.firezone.android.tunnel.SessionFactory

/**
 * What a debug launch can put in place of connlib and the portal, as a release build sees it:
 * nothing. The `debug` source set defines the object that reads the stand-ins off the launch, so
 * none of them is compiled into a release.
 */
object DebugOverrides {
    val sessionFactory: SessionFactory? = null

    fun configure(activity: Activity) = Unit

    fun authCallback(state: String?): Uri? = null
}
