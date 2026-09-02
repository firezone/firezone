// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.auth.notifications

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Context.NOTIFICATION_SERVICE
import android.content.Intent
import androidx.core.app.NotificationCompat
import dev.firezone.android.R
import dev.firezone.android.core.presentation.MainActivity

internal object AuthNotification {
    private const val CHANNEL_ID = "firezone-authentication-status"
    private const val CHANNEL_NAME = "firezone-authentication-status"
    private const val CHANNEL_DESCRIPTION = "Firezone authentication status"
    const val ID = 1338

    fun update(
        context: Context,
        status: StatusType,
    ): NotificationCompat.Builder {
        val manager = context.getSystemService(NOTIFICATION_SERVICE) as NotificationManager

        val channel =
            NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_DEFAULT,
            )
        channel.description = CHANNEL_DESCRIPTION
        manager.createNotificationChannel(channel)

        val builder =
            NotificationCompat
                .Builder(context, CHANNEL_ID)
                .setContentIntent(mainActivityPendingIntent(context))
        return status.applySettings(builder)
    }

    private fun mainActivityPendingIntent(context: Context): PendingIntent =
        PendingIntent.getActivity(
            context,
            0,
            Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    data class Error(
        val message: String,
    ) : StatusType() {
        override fun applySettings(builder: NotificationCompat.Builder): NotificationCompat.Builder =
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
