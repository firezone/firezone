/* Licensed under Apache 2.0 (C) 2024 Firezone, Inc. */
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.util.Log
import com.google.gson.Gson
import dev.firezone.android.tunnel.ConnlibSession
import dev.firezone.android.tunnel.TunnelService
import java.net.InetAddress

class NetworkMonitor(private val tunnelService: TunnelService) : ConnectivityManager.NetworkCallback() {
    private var lastNetwork: Network? = null
    private var lastDns: List<InetAddress>? = null

    override fun onLinkPropertiesChanged(
        network: Network,
        linkProperties: LinkProperties,
    ) {
        Log.d("NetworkMonitor", "OnLinkPropertiesChanged: $network: $linkProperties")
        if (tunnelService.tunnelState != TunnelService.Companion.State.UP) {
            tunnelService.tunnelState = TunnelService.Companion.State.UP
            tunnelService.updateStatusNotification("Status: Connected")
        }

        if (lastDns != linkProperties.dnsServers) {
            lastDns = linkProperties.dnsServers
            ConnlibSession.setDns(tunnelService.connlibSessionPtr!!, Gson().toJson(linkProperties.dnsServers))
        }

        if (lastNetwork != network) {
            lastNetwork = network
            ConnlibSession.reconnect(tunnelService.connlibSessionPtr!!)
        }
        super.onLinkPropertiesChanged(network, linkProperties)
    }
}
