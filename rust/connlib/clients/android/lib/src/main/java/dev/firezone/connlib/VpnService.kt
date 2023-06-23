package dev.firezone.connlib
import android.util.Log

public class VpnService : android.net.VpnService() {
    public override fun onCreate() {
        super.onCreate()
        Log.d("Connlib", "VpnService.onCreate")
    }

    public override fun onDestroy() {
        super.onDestroy()
        Log.d("Connlib", "VpnService.onDestroy")
    }

    public override fun onStartCommand(intent: android.content.Intent?, flags: Int, startId: Int): Int {
        Log.d("Connlib", "VpnService.onStartCommand")
        return super.onStartCommand(intent, flags, startId)
    }
}
