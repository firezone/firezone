/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.tunnel.callback

import dev.firezone.android.tunnel.data.TunnelRepository
import dev.firezone.android.tunnel.model.Resource

interface TunnelListener {
    fun onTunnelStateUpdate(state: TunnelRepository.Companion.TunnelState)

    fun onResourcesUpdate(resources: List<Resource>?)
}
