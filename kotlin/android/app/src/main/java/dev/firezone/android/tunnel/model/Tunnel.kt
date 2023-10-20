/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.tunnel.model

import android.os.Parcelable
import com.squareup.moshi.JsonClass
import kotlinx.parcelize.Parcelize

@JsonClass(generateAdapter = true)
@Parcelize
data class Tunnel(
    val config: TunnelConfig = TunnelConfig(),
    var state: State = State.Down,
    val routes: List<Cidr> = emptyList(),
    val resources: List<Resource> = emptyList(),
) : Parcelable {
    enum class State {
        Connecting,
        Up,
        Down,
        Closed,
    }
}
