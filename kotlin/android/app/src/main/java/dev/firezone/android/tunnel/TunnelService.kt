package dev.firezone.android.tunnel

import android.net.VpnService
import android.util.Log

class TunnelService: VpnService() {
    override fun onCreate() {
        super.onCreate()
        Log.d("FirezoneVpnService", "onCreate")
    }

    override fun onDestroy() {
        super.onDestroy()
        Log.d("FirezoneVpnService", "onDestroy")
    }

    override fun onStartCommand(intent: android.content.Intent?, flags: Int, startId: Int): Int {
        Log.d("FirezoneVpnService", "onStartCommand")
        return super.onStartCommand(intent, flags, startId)
    }


    companion object {
        val ACTION_CONNECT = "dev.firezone.android.tunnel.CONNECT"
        val ACTION_DISCONNECT = "dev.firezone.android.tunnel.DISCONNECT"
    }
}
