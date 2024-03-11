/* Licensed under Apache 2.0 (C) 2024 Firezone, Inc. */
package dev.firezone.android.features.session.backend

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

internal class BootShutdownReceiver : BroadcastReceiver() {
    override fun onReceive(
        context: Context,
        intent: Intent,
    ) {
        if (Intent.ACTION_BOOT_COMPLETED == intent.action) {
            Log.d("BootShutdownReceiver", "Boot completed. Attempting to connect.")
            // TODO: Retrieve the session manager from the application context.
            // sessionManager.connect()
        } else if (Intent.ACTION_SHUTDOWN == intent.action) {
            Log.d("BootShutdownReceiver", "Shutting down. Attempting to disconnect.")
            // TODO: Retrieve the session manager from the application context.
            // sessionManager.disconnect()
        }
    }
}
