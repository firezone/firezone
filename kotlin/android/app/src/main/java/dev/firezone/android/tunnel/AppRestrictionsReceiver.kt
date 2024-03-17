package dev.firezone.android.tunnel

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent


class AppRestrictionsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (Intent.ACTION_APPLICATION_RESTRICTIONS_CHANGED != intent.action) {
            return
        }

        val disconnectIntent = Intent(context, TunnelService::class.java).setAction("dev.firezone.android.tunnel.action.DISCONNECT")
        context.startService(disconnectIntent)

        val connectIntent = Intent(context, TunnelService::class.java)
        context.startService(connectIntent)
    }
}