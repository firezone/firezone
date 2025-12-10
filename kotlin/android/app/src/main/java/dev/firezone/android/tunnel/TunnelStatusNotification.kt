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
    const val ID = 1337
    private const val TITLE = "Firezone Connection Status"
    private const val TAG: String = "TunnelStatusNotification"

    fun update(
        context: Context,
        status: StatusType,
    ): NotificationCompat.Builder {
        val manager = context.getSystemService(NOTIFICATION_SERVICE) as NotificationManager

        val chan =
            NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_DEFAULT,
            )
        chan.description = CHANNEL_DESCRIPTION
        manager.createNotificationChannel(chan)

        val notificationBuilder =
            NotificationCompat
                .Builder(context, CHANNEL_ID)
                .setContentIntent(configIntent(context))
        return status.applySettings(notificationBuilder)
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

    data object SignedOut : StatusType() {
        private const val MESSAGE = "Status: Signed out. Tap here to sign in."

        override fun applySettings(builder: NotificationCompat.Builder) =
            builder
                .setSmallIcon(R.drawable.ic_firezone_logo)
                .setContentTitle(TITLE)
                .setContentText(MESSAGE)
                .setCategory(NotificationCompat.CATEGORY_ERROR)
                .setPriority(NotificationManager.IMPORTANCE_HIGH)
                .setAutoCancel(true)
    }

    data object Connecting : StatusType() {
        private const val MESSAGE = "Status: Connecting..."

        override fun applySettings(builder: NotificationCompat.Builder) =
            builder
                .setSmallIcon(R.drawable.ic_firezone_logo)
                .setContentTitle(TITLE)
                .setContentText(MESSAGE)
                .setCategory(Notification.CATEGORY_SERVICE)
                .setPriority(NotificationManager.IMPORTANCE_MIN)
                .setOngoing(true)
    }

    data object Connected : StatusType() {
        private const val MESSAGE = "Status: Connected"

        override fun applySettings(builder: NotificationCompat.Builder) =
            builder
                .setSmallIcon(R.drawable.ic_firezone_logo)
                .setContentTitle(TITLE)
                .setContentText(MESSAGE)
                .setCategory(Notification.CATEGORY_SERVICE)
                .setPriority(NotificationManager.IMPORTANCE_MIN)
                .setOngoing(true)
    }

    sealed class StatusType {
        abstract fun applySettings(builder: NotificationCompat.Builder): NotificationCompat.Builder
    }
}
