package dev.firezone.android.features.session.backend

import android.content.BroadcastReceiver
import android.util.Log
import android.content.Context
import android.content.Intent
import javax.inject.Inject
import kotlinx.coroutines.CoroutineDispatcher

internal class BootShutdownReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (Intent.ACTION_BOOT_COMPLETED == intent.action) {
            Log.d("BootShutdownReceiver", "Boot completed. Attempting to connect.")
            // TODO: Inject sessionManager to connect on boot
            // sessionManager.connect()
        } else if (Intent.ACTION_SHUTDOWN == intent.action) {
            Log.d("BootShutdownReceiver", "Shutting down. Attempting to disconnect.")
            // TODO: Inject sessionManager to disconnect on shutdown
            // sessionManager.disconnect()
        }
    }
}
