// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.tunnel

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Context.NOTIFICATION_SERVICE
import android.content.Intent
import androidx.core.app.NotificationCompat
import dev.firezone.android.R
import dev.firezone.android.core.presentation.MainActivity

object TunnelErrorNotification {
    private const val CHANNEL_ID = "firezone-tunnel-errors"
    private const val CHANNEL_NAME = "Connection Errors"
    private const val CHANNEL_DESCRIPTION = "Notifications for gateway connection errors"
    const val ID = 1339
    private const val TAG: String = "TunnelErrorNotification"

    fun create(
        context: Context,
        title: String,
        message: String,
    ): NotificationCompat.Builder {
        val manager = context.getSystemService(NOTIFICATION_SERVICE) as NotificationManager

        val chan =
            NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_HIGH,
            )
        chan.description = CHANNEL_DESCRIPTION
        manager.createNotificationChannel(chan)

        val notificationBuilder =
            NotificationCompat
                .Builder(context, CHANNEL_ID)
                .setContentIntent(configIntent(context))
                .setSmallIcon(R.drawable.ic_firezone_logo)
                .setContentTitle(title)
                .setContentText(message)
                .setStyle(NotificationCompat.BigTextStyle().bigText(message))
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setAutoCancel(true)

        return notificationBuilder
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
