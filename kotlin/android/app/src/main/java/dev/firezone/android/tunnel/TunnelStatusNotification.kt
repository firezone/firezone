// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.tunnel

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Context.NOTIFICATION_SERVICE
import android.content.Intent
import androidx.core.app.NotificationCompat
import dev.firezone.android.R
import dev.firezone.android.core.presentation.MainActivity

object TunnelStatusNotification {
    private const val CHANNEL_ID = "firezone-connection-status"
    private const val CHANNEL_NAME = "firezone-connection-status"
    private const val CHANNEL_DESCRIPTION = "Firezone connection status"

    private const val DISCONNECTED_CHANNEL_ID = "firezone-disconnected"
    private const val DISCONNECTED_CHANNEL_NAME = "Firezone Disconnected"
    private const val DISCONNECTED_CHANNEL_DESCRIPTION = "Notifications when Firezone disconnects"

    const val CONNECTED_NOTIFICATION_ID = 1337
    const val DISCONNECTED_NOTIFICATION_ID = 1338

    private const val TITLE = "Firezone"
    private const val TAG: String = "TunnelStatusNotification"

    /**
     * Creates and returns a sticky notification for connected state.
     * This notification is ongoing and cannot be dismissed by the user.
     */
    fun createConnectedNotification(context: Context): Notification {
        val manager = context.getSystemService(NOTIFICATION_SERVICE) as NotificationManager

        val channel =
            NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_LOW,
            )
        channel.description = CHANNEL_DESCRIPTION
        manager.createNotificationChannel(channel)

        return NotificationCompat
            .Builder(context, CHANNEL_ID)
            .setContentIntent(configIntent(context))
            .setSmallIcon(R.drawable.ic_firezone_logo)
            .setContentTitle(TITLE)
            .setContentText("Connected")
            .setCategory(Notification.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .build()
    }

    /**
     * Shows a dismissable notification when the tunnel disconnects.
     * This notification can be dismissed by the user.
     */
    fun showDisconnectedNotification(context: Context) {
        val manager = context.getSystemService(NOTIFICATION_SERVICE) as NotificationManager

        val channel =
            NotificationChannel(
                DISCONNECTED_CHANNEL_ID,
                DISCONNECTED_CHANNEL_NAME,
                NotificationManager.IMPORTANCE_DEFAULT,
            )
        channel.description = DISCONNECTED_CHANNEL_DESCRIPTION
        manager.createNotificationChannel(channel)

        val notification =
            NotificationCompat
                .Builder(context, DISCONNECTED_CHANNEL_ID)
                .setContentIntent(configIntent(context))
                .setSmallIcon(R.drawable.ic_firezone_logo)
                .setContentTitle("Your Firezone session has ended")
                .setContentText("Please sign in again to reconnect")
                .setCategory(NotificationCompat.CATEGORY_STATUS)
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .setAutoCancel(true)
                .build()

        manager.notify(DISCONNECTED_NOTIFICATION_ID, notification)
    }

    /**
     * Dismisses the disconnected notification if it's showing.
     */
    fun dismissDisconnectedNotification(context: Context) {
        val manager = context.getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        manager.cancel(DISCONNECTED_NOTIFICATION_ID)
    }

    private fun configIntent(context: Context): PendingIntent {
        val intent = Intent(context, MainActivity::class.java)
        intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
        return PendingIntent.getActivity(
            context,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}
