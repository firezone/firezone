/* Licensed under Apache 2.0 (C) 2024 Firezone, Inc. */
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import com.google.gson.Gson
import dev.firezone.android.tunnel.ConnlibSession

class NetworkMonitor(private val connlibSessionPtr: Long) : ConnectivityManager.NetworkCallback() {
    override fun onLinkPropertiesChanged(
        network: Network,
        linkProperties: LinkProperties,
    ) {
        ConnlibSession.setDns(connlibSessionPtr, Gson().toJson(linkProperties.dnsServers))
        ConnlibSession.reconnect(connlibSessionPtr)
        super.onLinkPropertiesChanged(network, linkProperties)
    }
}
