// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.tunnel.model

import android.os.Parcelable
import kotlinx.parcelize.Parcelize

@Parcelize
data class ConnectedDevice(
    val id: String,
    val pools: List<String>,
) : Parcelable
