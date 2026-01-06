// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.tunnel.model

import android.os.Parcelable
import com.squareup.moshi.Json
import com.squareup.moshi.JsonClass
import kotlinx.parcelize.Parcelize

@JsonClass(generateAdapter = true)
@Parcelize
data class Resource(
    val type: ResourceType,
    val id: String,
    val address: String?,
    @Json(name = "address_description") val addressDescription: String?,
    val sites: List<Site>?,
    val name: String,
    val status: StatusEnum,
) : Parcelable

fun Resource.isInternetResource(): Boolean = this.type == ResourceType.Internet

enum class ResourceType {
    @Json(name = "dns")
    DNS,

    @Json(name = "ip")
    IP,

    @Json(name = "cidr")
    CIDR,

    @Json(name = "internet")
    Internet,
}

enum class StatusEnum {
    @Json(name = "Unknown")
    UNKNOWN,

    @Json(name = "Offline")
    OFFLINE,

    @Json(name = "Online")
    ONLINE,
}
