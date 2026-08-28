// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.customuri.ui

import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.core.presentation.MainActivity
import dev.firezone.android.features.customuri.notifications.CustomUriNotification
import dev.firezone.android.features.customuri.ui.compose.CustomUriScreen
import dev.firezone.android.tunnel.TunnelService
import dev.firezone.android.ui.theme.FirezoneTheme
import kotlinx.coroutines.launch

@AndroidEntryPoint
class CustomUriHandlerActivity : AppCompatActivity() {
    private val viewModel: CustomUriViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        setContent {
            FirezoneTheme {
                CustomUriScreen()
            }
        }

        setupActionObservers()
        viewModel.parseCustomUri(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        viewModel.parseCustomUri(intent)
    }

    private fun setupActionObservers() {
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                viewModel.actionStateFlow.collect { action ->
                    action?.let {
                        viewModel.clearAction()
                        when (it) {
                            CustomUriViewModel.ViewAction.AuthFlowComplete -> {
                                TunnelService.start(this@CustomUriHandlerActivity)
                                startActivity(
                                    Intent(this@CustomUriHandlerActivity, MainActivity::class.java),
                                )
                            }

                            is CustomUriViewModel.ViewAction.AuthFlowError -> {
                                notifyError("Errors occurred during authentication:\n${it.errors.joinToString(separator = "\n")}")
                                startActivity(Intent(this@CustomUriHandlerActivity, MainActivity::class.java))
                            }
                        }

                        finish()
                    }
                }
            }
        }
    }

    private fun notifyError(message: String) {
        val notification = CustomUriNotification.update(this, CustomUriNotification.Error(message)).build()
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(CustomUriNotification.ID, notification)
    }
}
