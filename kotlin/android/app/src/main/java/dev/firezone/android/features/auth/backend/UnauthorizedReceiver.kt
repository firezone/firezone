/* Licensed under Apache 2.0 (C) 2024 Firezone, Inc. */
package dev.firezone.android.features.auth.backend

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import dev.firezone.android.R
import dev.firezone.android.core.presentation.MainActivity

class UnauthorizedReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "UnauthorizedReceiver"

        private const val NOTIFICATION_CHANNEL_ID = "firezone-auth-status"
        private const val NOTIFICATION_CHANNEL_NAME = "firezone-auth-status"
        private const val RESIGN_IN_NOTIFICATION_ID = 1
        private const val RESIGN_IN_NOTIFICATION_TITLE = "Session Disconnected"
        private const val RESIGN_IN_NOTIFICATION_TEXT = "Click to sign in again."
    }

    override fun onReceive(
        context: Context?,
        intent: Intent?,
    ) {
        Log.d(TAG, "onReceive")
        if (isUserSignedIn(context)) {
            Log.d(TAG, "User is signed in")
            sendNotification(context!!)
        }
    }

    private fun isUserSignedIn(context: Context?): Boolean {
        return context != null
    }

    private fun sendNotification(context: Context) {
        Log.d(TAG, "sendNotification")

        val chan =
            NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                NOTIFICATION_CHANNEL_NAME,
                NotificationManager.IMPORTANCE_HIGH,
            )
        chan.description = "firezone authentication"

        val builder =
            NotificationCompat.Builder(context, NOTIFICATION_CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_firezone_logo)
                .setContentTitle(RESIGN_IN_NOTIFICATION_TITLE)
                .setContentText(RESIGN_IN_NOTIFICATION_TEXT)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setCategory(NotificationCompat.CATEGORY_STATUS)
                .setContentIntent(configIntent(context))
                .setAutoCancel(true)

        with(NotificationManagerCompat.from(context)) {
            createNotificationChannel(chan)
            val permission =
                ActivityCompat.checkSelfPermission(
                    context,
                    "android.permission.POST_NOTIFICATIONS",
                )
            if (permission != PackageManager.PERMISSION_GRANTED) {
                Log.e(TAG, "Can't request sign in because 'POST_NOTIFICATIONS' permission is not 'PERMISSION_GRANTED'. It is $permission")
                // TODO: Consider calling
                //    ActivityCompat#requestPermissions
                // here to request the missing permissions, and then overriding
                //   public void onRequestPermissionsResult(int requestCode, String[] permissions,
                //                                          int[] grantResults)
                // to handle the case where the user grants the permission. See the documentation
                // for ActivityCompat#requestPermissions for more details.
                return
            }
            Log.d(TAG, "sendNotification: notifying")
            notify(RESIGN_IN_NOTIFICATION_ID, builder.build())
        }
    }

    private fun configIntent(context: Context): PendingIntent? {
        return PendingIntent.getActivity(
            context,
            0,
            Intent(context, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}
