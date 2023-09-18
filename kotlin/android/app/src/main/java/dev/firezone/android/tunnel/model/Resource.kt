package dev.firezone.android.tunnel.model

import android.os.Parcelable
import com.squareup.moshi.JsonClass
import kotlinx.parcelize.Parcelize

@JsonClass(generateAdapter = true)
@Parcelize
data class Resource(
    val type: String,
    val id: String,
    val address: String,
    val name: String,
): Parcelable
