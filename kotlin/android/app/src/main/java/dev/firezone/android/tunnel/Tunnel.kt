package dev.firezone.android.tunnel

class Tunnel(
    val config: TunnelConfig,
    var state: State = State.Down
) {

    sealed interface State {
        object Up: State
        object Down: State
    }
}
