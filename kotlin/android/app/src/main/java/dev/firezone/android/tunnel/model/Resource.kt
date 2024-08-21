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
    @Json(name = "address_description") val addressDescription: String?,
    val sites: List<Site>?,
    val name: String,
    val status: StatusEnum,
    var enabled: Boolean = true,
    @Json(name = "can_be_disabled") val canBeDisabled: Boolean,
) : Parcelable

enum class TypeEnum {
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
