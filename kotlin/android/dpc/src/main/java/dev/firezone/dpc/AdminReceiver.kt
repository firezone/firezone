// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.dpc

import android.app.admin.DeviceAdminReceiver
import android.content.ComponentName
import android.content.Context

class AdminReceiver : DeviceAdminReceiver() {
    companion object {
        fun componentName(context: Context) = ComponentName(context, AdminReceiver::class.java)
    }
}
