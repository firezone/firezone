package dev.firezone.android.tunnel.model

import com.squareup.moshi.JsonClass

@JsonClass(generateAdapter = true)
data class Resource(
    val type: String,
    val id: String,
    val address: String,
    val name: String,
)
