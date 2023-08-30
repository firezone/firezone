package dev.firezone.android.tunnel.model

data class Tunnel(
    val config: TunnelConfig,
    var state: State = State.Down,
    val routes: MutableList<String> = mutableListOf(),
    val resources: MutableList<String> = mutableListOf(),
) {

    sealed interface State {
        object Up: State
        object CONNECTING: State
        object Down: State
    }
}
