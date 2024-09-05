/* Licensed under Apache 2.0 (C) 2024 Firezone, Inc. */
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.os.Handler
import android.os.Looper
import android.util.Log
import dev.firezone.android.tunnel.TunnelService

// None of the TunnelService lifecycle callbacks are called when a user disconnects the VPN
// from the system settings. This class listens for network changes and shuts down the service
// when the network is lost, which achieves the same effect.
class DisconnectMonitor(private val tunnelService: TunnelService) : ConnectivityManager.NetworkCallback() {
    private var vpnNetwork: Network? = null

    // This handler is used to stop connlib when the VPN fd is lost
    private var sessionStopperHandle: Handler = Handler(Looper.getMainLooper())

    // Android doesn't provide a good way to associate a network with a VPN service, so we
    // have to use the IP addresses of the tunnel to determine if the network is our VPN.
    override fun onLinkPropertiesChanged(
        network: Network,
        linkProperties: LinkProperties,
    ) {
        Log.d("DisconnectMonitor", "properties: $linkProperties")

        super.onLinkPropertiesChanged(network, linkProperties)

        if (tunnelService.tunnelIpv4Address.isNullOrBlank() || tunnelService.tunnelIpv6Address.isNullOrBlank()) {
            return
        }

        val ipv4Found = linkProperties.linkAddresses.find { it.address.hostAddress == tunnelService.tunnelIpv4Address }
        val ipv6Found = linkProperties.linkAddresses.find { it.address.hostAddress == tunnelService.tunnelIpv6Address }

        if (ipv4Found != null && ipv6Found != null) {
            // When we get onLinkPropertiesChanged it means the interface is available again and we
            // should abort stopping the session
            sessionStopperHandle.removeCallbacksAndMessages(null)
            // Matched both IPv4 and IPv6 addresses, this is our VPN network
            vpnNetwork = network
        }
    }

    override fun onLost(network: Network) {
        if (network == vpnNetwork) {
            Log.d("DisconnectMonitor", "Scheduling a session disconnect for $network")

            // We delay the execution of disconnecting the tunnel when the network is lost since
            // when the tunnel is rebuild we get an onLost just like with disabling the VPN and we
            // can't distinguish between those save for getting an onLinkProperties changed later
            sessionStopperHandle.postDelayed(
                {
                    Log.d("DisconnectMonitor", "Disconnect tunnel service due to network lost $network")
                    tunnelService.disconnect()
                },
                2000,
            )
        }

        super.onLost(network)
    }
}
