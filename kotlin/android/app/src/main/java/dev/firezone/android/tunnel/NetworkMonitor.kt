// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import dev.firezone.android.tunnel.TunnelService
import dev.firezone.android.tunnel.TunnelStatusNotification
import java.net.InetAddress

class NetworkMonitor(
    private val tunnelService: TunnelService,
) : ConnectivityManager.NetworkCallback() {
    private var lastNetwork: Network? = null
    private var lastDns: List<InetAddress>? = null

    override fun onLinkPropertiesChanged(
        network: Network,
        linkProperties: LinkProperties,
    ) {
        if (tunnelService.tunnelState != TunnelService.Companion.State.UP) {
            tunnelService.tunnelState = TunnelService.Companion.State.UP
            tunnelService.updateStatusNotification(TunnelStatusNotification.Connected)
        }

        if (lastDns != linkProperties.dnsServers) {
            lastDns = linkProperties.dnsServers

            // Strip the scope id from IPv6 addresses. See https://github.com/firezone/firezone/issues/5781
            val dnsList =
                linkProperties.dnsServers.mapNotNull {
                    it.hostAddress?.split("%")?.getOrNull(0)
                }
            tunnelService.setDns(dnsList)
        }

        if (lastNetwork != network) {
            lastNetwork = network
            tunnelService.reset()
        }

        super.onLinkPropertiesChanged(network, linkProperties)
    }
}
