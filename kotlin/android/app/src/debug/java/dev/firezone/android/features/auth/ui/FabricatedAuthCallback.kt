// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.auth.ui

import android.net.Uri
import dev.firezone.android.features.auth.AUTH_CALLBACK_HOST
import dev.firezone.android.features.auth.AUTH_CALLBACK_SCHEME

/**
 * The callback the portal would send back for a request that issued [state], so the pending
 * request still has to match it.
 */
internal fun fabricatedAuthCallback(state: String?): Uri =
    Uri
        .parse("$AUTH_CALLBACK_SCHEME://$AUTH_CALLBACK_HOST")
        .buildUpon()
        .appendQueryParameter("state", state)
        .appendQueryParameter("fragment", "skip-portal-auth")
        .build()
