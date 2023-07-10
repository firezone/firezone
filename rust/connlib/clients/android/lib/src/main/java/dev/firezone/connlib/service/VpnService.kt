package dev.firezone.connlib.service
import android.util.Log

class VpnService : android.net.VpnService() {
    override fun onCreate() {
        super.onCreate()
        Log.d("Connlib", "VpnService.onCreate")
    }

    override fun onDestroy() {
        super.onDestroy()
        Log.d("Connlib", "VpnService.onDestroy")
    }

    override fun onStartCommand(intent: android.content.Intent?, flags: Int, startId: Int): Int {
        Log.d("Connlib", "VpnService.onStartCommand")
        return super.onStartCommand(intent, flags, startId)
    }
}
