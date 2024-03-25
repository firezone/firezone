/* Licensed under Apache 2.0 (C) 2024 Firezone, Inc. */
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.util.Log
import com.google.gson.Gson
import dev.firezone.android.tunnel.ConnlibSession
import java.net.InetAddress

class NetworkMonitor(private val connlibSessionPtr: Long) : ConnectivityManager.NetworkCallback() {
    private var lastNetwork: Network? = null
    private var lastDns: List<InetAddress>? = null

    override fun onLinkPropertiesChanged(
        network: Network,
        linkProperties: LinkProperties,
    ) {
        Log.d("NetworkMonitor", "OnLinkPropertiesChanged: $network: $linkProperties")

        if (lastDns != linkProperties.dnsServers) {
            lastDns = linkProperties.dnsServers
            ConnlibSession.setDns(connlibSessionPtr, Gson().toJson(linkProperties.dnsServers))
        }

        if (lastNetwork != network) {
            lastNetwork = network
            ConnlibSession.reconnect(connlibSessionPtr)
        }
        super.onLinkPropertiesChanged(network, linkProperties)
    }
}
