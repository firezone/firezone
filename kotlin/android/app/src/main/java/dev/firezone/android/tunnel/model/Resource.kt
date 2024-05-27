/* Licensed under Apache 2.0 (C) 2024 Firezone, Inc. */
package dev.firezone.android.tunnel.model

import android.os.Parcelable
import com.squareup.moshi.Json
import com.squareup.moshi.JsonClass
import kotlinx.parcelize.Parcelize

@JsonClass(generateAdapter = true)
@Parcelize
data class Resource(
    val type: TypeEnum,
    val id: String,
    val address: String,
    val addressDescription: String?,
    val sites: List<Site>?,
    val name: String,
    val status: StatusEnum,
) : Parcelable

enum class TypeEnum {
    @Json(name = "dns")
    DNS,

    @Json(name = "ip")
    IP,

    @Json(name = "cidr")
    CIDR,
}

enum class StatusEnum {
    @Json(name = "Unknown")
    UNKNOWN,

    @Json(name = "Offline")
    OFFLINE,

    @Json(name = "Online")
    ONLINE,
}