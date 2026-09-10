// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core

import dev.firezone.android.tunnel.SessionFactory

/**
 * What a debug launch puts in place of the real thing.
 *
 * Only the `debug` source set writes these, so a release build reads the defaults and takes every
 * real path. Both are read after the Hilt graph exists, which is what lets the launcher set them.
 */
object DebugOverrides {
    /** Stands in for connlib, so the app runs with no portal and no tunnel. */
    @Volatile
    var sessionFactory: SessionFactory? = null

    /** Signs in against a fabricated callback rather than sending the user to the portal. */
    @Volatile
    var skipPortalAuth: Boolean = false
}
