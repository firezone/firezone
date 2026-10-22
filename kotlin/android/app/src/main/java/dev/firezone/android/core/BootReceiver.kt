// Licensed under Apache 2.0 (C) 2025 Firezone, Inc.
package dev.firezone.android.core

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.VpnService
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.di.ApplicationScope
import dev.firezone.android.tunnel.TunnelNotification
import dev.firezone.android.tunnel.TunnelService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import javax.inject.Inject

@AndroidEntryPoint
class BootReceiver : BroadcastReceiver() {
    @Inject
    lateinit var repo: Repository

    @Inject
    @ApplicationScope
    lateinit var applicationScope: CoroutineScope

    override fun onReceive(
        context: Context,
        intent: Intent,
    ) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) {
            val appContext = context.applicationContext

            applicationScope.launch(Dispatchers.IO) {
                val userConfig = repo.getConfigSync()
                if (!userConfig.startOnLogin) {
                    return@launch
                }

                // Nothing has prepared us as this device's VPN since the reboot, and until
                // something does, the system refuses to keep connlib's sockets out of the tunnel.
                // `prepare` returns null once it has prepared us again; an Intent means our consent
                // is gone, and launching that needs an Activity we do not have here.
                if (VpnService.prepare(appContext) != null) {
                    TunnelNotification.showVpnPermissionRequiredNotification(appContext)
                    return@launch
                }

                TunnelService.start(appContext, TunnelService.StartSource.BOOT)
            }
        }
    }
}
