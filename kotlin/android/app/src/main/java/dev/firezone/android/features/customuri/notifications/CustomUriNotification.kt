// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.customuri.notifications

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Context.NOTIFICATION_SERVICE
import android.content.Intent
import androidx.core.app.NotificationCompat
import dev.firezone.android.R
import dev.firezone.android.core.presentation.MainActivity

object CustomUriNotification {
    private const val CHANNEL_ID = "firezone-authentication-status"
    private const val CHANNEL_NAME = "firezone-authentication-status"
    private const val CHANNEL_DESCRIPTION = "Firezone authentication status"
    const val ID = 1338
    private const val TAG: String = "CustomUriNotification"

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

    data class Error(
        val message: String,
    ) : StatusType() {
        override fun applySettings(builder: NotificationCompat.Builder) =
            builder.apply {
                setSmallIcon(R.drawable.ic_firezone_logo)
                setContentTitle("Authentication Error")
                setContentText(message)
                setStyle(NotificationCompat.BigTextStyle().bigText(message))
                setPriority(NotificationCompat.PRIORITY_HIGH)
                setAutoCancel(true)
            }
    }

    sealed class StatusType {
        abstract fun applySettings(builder: NotificationCompat.Builder): NotificationCompat.Builder
    }
}
