// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.signin.ui

import android.content.Context
import dev.firezone.android.R
import uniffi.x509claims.Identity

internal fun startSessionLabel(
    context: Context,
    identity: Identity,
): String =
    when (identity) {
        Identity.Absent -> context.getString(R.string.sign_in)
        is Identity.Claimed -> identity.email?.let { context.getString(R.string.connect_as, it) } ?: context.getString(R.string.connect)
    }
