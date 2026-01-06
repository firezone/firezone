// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.tunnel.model

import android.os.Parcelable
import com.squareup.moshi.JsonClass
import kotlinx.parcelize.Parcelize

@JsonClass(generateAdapter = true)
@Parcelize
data class Cidr(
    // TODO: Not convinced of using String to store address, we can make a moshi InetAddress adapter
    val address: String,
    val prefix: Int,
) : Parcelable
