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

/**
 * Unified notification manager for all Firezone tunnel notifications.
 * Handles connected status, disconnected status, and error notifications.
 */
object TunnelNotification {
    // Channel IDs
    private const val STATUS_CHANNEL_ID = "firezone-connection-status"
    private const val DISCONNECTED_CHANNEL_ID = "firezone-disconnected"
    private const val ERROR_CHANNEL_ID = "firezone-tunnel-errors"

    // Channel Names
    private const val STATUS_CHANNEL_NAME = "Connection Status"
    private const val DISCONNECTED_CHANNEL_NAME = "Disconnected Status"
    private const val ERROR_CHANNEL_NAME = "Connection Errors"

    // Channel Descriptions
    private const val STATUS_CHANNEL_DESCRIPTION = "Firezone connection status"
    private const val DISCONNECTED_CHANNEL_DESCRIPTION = "Notifications when Firezone disconnects"
    private const val ERROR_CHANNEL_DESCRIPTION = "Notifications for gateway connection errors"

    // Notification IDs
    const val CONNECTED_NOTIFICATION_ID = 1337
    const val DISCONNECTED_NOTIFICATION_ID = 1338
    const val ERROR_NOTIFICATION_ID = 1339

    private const val TAG = "TunnelNotification"

    /**
     * Creates and returns a sticky notification for connected state.
     * This notification is ongoing and cannot be dismissed by the user.
     * Should be used with Service.startForeground().
     */
    fun createConnectedNotification(context: Context): Notification {
        ensureChannelExists(
            context,
            STATUS_CHANNEL_ID,
            STATUS_CHANNEL_NAME,
            STATUS_CHANNEL_DESCRIPTION,
            NotificationManager.IMPORTANCE_LOW,
        )

        return NotificationCompat
            .Builder(context, STATUS_CHANNEL_ID)
            .setContentIntent(createMainActivityIntent(context))
            .setSmallIcon(R.drawable.ic_firezone_logo)
            .setContentTitle("Firezone")
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
        ensureChannelExists(
            context,
            DISCONNECTED_CHANNEL_ID,
            DISCONNECTED_CHANNEL_NAME,
            DISCONNECTED_CHANNEL_DESCRIPTION,
            NotificationManager.IMPORTANCE_DEFAULT,
        )

        val notification =
            NotificationCompat
                .Builder(context, DISCONNECTED_CHANNEL_ID)
                .setContentIntent(createMainActivityIntent(context))
                .setSmallIcon(R.drawable.ic_firezone_logo)
                .setContentTitle("Your Firezone session has ended")
                .setContentText("Please sign in again to reconnect")
                .setCategory(NotificationCompat.CATEGORY_STATUS)
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .setAutoCancel(true)
                .build()

        val manager = context.getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(DISCONNECTED_NOTIFICATION_ID, notification)
    }

    /**
     * Dismisses the disconnected notification if it's showing.
     */
    fun dismissDisconnectedNotification(context: Context) {
        val manager = context.getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        manager.cancel(DISCONNECTED_NOTIFICATION_ID)
    }

    /**
     * Shows an error notification with the given title and message.
     * This notification is dismissable and has high priority.
     */
    fun showErrorNotification(
        context: Context,
        title: String,
        message: String,
    ) {
        ensureChannelExists(
            context,
            ERROR_CHANNEL_ID,
            ERROR_CHANNEL_NAME,
            ERROR_CHANNEL_DESCRIPTION,
            NotificationManager.IMPORTANCE_HIGH,
        )

        val notification =
            NotificationCompat
                .Builder(context, ERROR_CHANNEL_ID)
                .setContentIntent(createMainActivityIntent(context))
                .setSmallIcon(R.drawable.ic_firezone_logo)
                .setContentTitle(title)
                .setContentText(message)
                .setStyle(NotificationCompat.BigTextStyle().bigText(message))
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setAutoCancel(true)
                .build()

        val manager = context.getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(ERROR_NOTIFICATION_ID, notification)
    }

    /**
     * Ensures a notification channel exists with the given parameters.
     * Creates the channel if it doesn't already exist.
     */
    private fun ensureChannelExists(
        context: Context,
        channelId: String,
        channelName: String,
        channelDescription: String,
        importance: Int,
    ) {
        val manager = context.getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(channelId, channelName, importance)
        channel.description = channelDescription
        manager.createNotificationChannel(channel)
    }

    /**
     * Creates a PendingIntent that opens the MainActivity.
     */
    private fun createMainActivityIntent(context: Context): PendingIntent {
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
