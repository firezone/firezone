/* Licensed under Apache 2.0 (C) 2024 Firezone, Inc. */
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import com.google.firebase.crashlytics.ktx.crashlytics
import com.google.firebase.ktx.Firebase
import com.google.gson.Gson
import dev.firezone.android.tunnel.ConnlibSession
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
        // Acquire mutex lock
        if (tunnelService.lock.tryLock()) {
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
                tunnelService.connlibSessionPtr?.let {
                    ConnlibSession.setDns(it, Gson().toJson(dnsList))
                } ?: Firebase.crashlytics.recordException(NullPointerException("connlibSessionPtr is null"))
            }

            if (lastNetwork != network) {
                lastNetwork = network
                tunnelService.connlibSessionPtr?.let {
                    ConnlibSession.reset(it)
                } ?: Firebase.crashlytics.recordException(NullPointerException("connlibSessionPtr is null"))
            }

            // Release mutex lock
            tunnelService.lock.unlock()
        }

        super.onLinkPropertiesChanged(network, linkProperties)
    }
}
