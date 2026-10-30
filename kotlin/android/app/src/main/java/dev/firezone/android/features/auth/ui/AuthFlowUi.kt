// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.auth.ui

import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import dev.firezone.android.core.presentation.MainActivity
import dev.firezone.android.features.auth.notifications.AuthNotification

internal fun notifyAuthError(
    context: Context,
    message: String,
) {
    val notification = AuthNotification.update(context, AuthNotification.Error(message)).build()
    val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    manager.notify(AuthNotification.ID, notification)
}

internal fun mainActivityHandoffIntent(context: Context): Intent =
    Intent(context, MainActivity::class.java).apply {
        flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
    }

internal fun mainActivityReturnIntent(context: Context): Intent = Intent(context, MainActivity::class.java)
