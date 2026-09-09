// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.cli

import android.os.Parcelable
import kotlinx.parcelize.Parcelize

@Parcelize
data class Status(
    val signedIn: Boolean,
    val accountSlug: String?,
    val actorName: String?,
    val tunnelIpv4: String?,
    val tunnelIpv6: String?,
) : Parcelable
