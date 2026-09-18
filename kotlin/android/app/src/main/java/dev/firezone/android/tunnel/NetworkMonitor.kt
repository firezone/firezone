// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.util.Log
import dev.firezone.android.tunnel.TunnelNotification
import dev.firezone.android.tunnel.TunnelService
import java.net.InetAddress

private const val TAG = "NetworkMonitor"

class NetworkMonitor(
    private val tunnelService: TunnelService,
) : ConnectivityManager.NetworkCallback() {
    private var lastNetwork: Network? = null
    private var lastDns: List<InetAddress>? = null

    override fun onLinkPropertiesChanged(
        network: Network,
        linkProperties: LinkProperties,
    ) {
        if (lastDns != linkProperties.dnsServers) {
            lastDns = linkProperties.dnsServers

            // Strip the scope id from IPv6 addresses. See https://github.com/firezone/firezone/issues/5781
            val dnsList =
                linkProperties.dnsServers.mapNotNull {
                    it.hostAddress?.split("%")?.getOrNull(0)
                }
            Log.d(TAG, "System DNS servers changed: $dnsList")
            tunnelService.setDns(dnsList)
        }

        if (lastNetwork != network) {
            lastNetwork = network
            Log.d(TAG, "Default network changed to $network")
            tunnelService.reset()
        }

        super.onLinkPropertiesChanged(network, linkProperties)
    }
}
