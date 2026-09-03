// Licensed under Apache 2.0 (C) 2025 Firezone, Inc.
package dev.firezone.android.core

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.core.data.ManagedConfigurationSource
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.di.ApplicationScope
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
    internal lateinit var managedConfigurationSource: ManagedConfigurationSource

    @Inject
    @ApplicationScope
    lateinit var applicationScope: CoroutineScope

    override fun onReceive(
        context: Context,
        intent: Intent,
    ) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) {
            val pendingResult = goAsync()
            applicationScope.launch(Dispatchers.IO) {
                try {
                    val managedConfiguration = managedConfigurationSource.refresh()
                    val config = repo.getEffectiveConfig(repo.getUserConfigSync(), managedConfiguration)
                    if (config.startOnLogin) {
                        val serviceIntent = Intent(context, TunnelService::class.java)
                        context.startService(serviceIntent)
                    }
                } finally {
                    pendingResult.finish()
                }
            }
        }
    }
}
