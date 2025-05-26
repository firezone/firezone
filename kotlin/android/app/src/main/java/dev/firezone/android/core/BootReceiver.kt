package dev.firezone.android.core

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import dev.firezone.android.tunnel.TunnelService
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.di.ApplicationScope
import dagger.hilt.android.AndroidEntryPoint
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

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) {
            applicationScope.launch(Dispatchers.IO) {
                val userConfig = repo.getConfigSync()
                if (userConfig.startOnBoot) {
                    val serviceIntent = Intent(context, TunnelService::class.java)
                    context.startService(serviceIntent)
                }
            }
        }
    }
}