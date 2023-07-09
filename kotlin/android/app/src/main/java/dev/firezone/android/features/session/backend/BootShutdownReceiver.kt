package dev.firezone.android.features.session.backend

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import javax.inject.Inject
import kotlinx.coroutines.CoroutineDispatcher

internal class BootShutdownReceiver @Inject constructor(
    private val coroutineDispatcher: CoroutineDispatcher,
    private val sessionManager: SessionManager
) : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (Intent.ACTION_BOOT_COMPLETED == intent.action) {
            sessionManager.connect()
        } else if (Intent.ACTION_SHUTDOWN == intent.action) {
            sessionManager.disconnect()
        }
    }
}
