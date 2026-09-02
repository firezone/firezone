// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.customuri.ui

import android.content.Intent
import android.os.Bundle
import androidx.activity.viewModels
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.R
import dev.firezone.android.features.auth.ui.mainActivityHandoffIntent
import dev.firezone.android.features.auth.ui.notifyAuthError
import dev.firezone.android.tunnel.TunnelService
import kotlinx.coroutines.launch

@AndroidEntryPoint
class CustomUriHandlerActivity : AppCompatActivity(R.layout.activity_custom_uri_handler) {
    private val viewModel: CustomUriViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

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
                        when (it) {
                            CustomUriViewModel.ViewAction.AuthFlowComplete -> {
                                TunnelService.start(this@CustomUriHandlerActivity)
                                startActivity(mainActivityHandoffIntent(this@CustomUriHandlerActivity))
                            }

                            is CustomUriViewModel.ViewAction.AuthFlowError -> {
                                notifyAuthError(
                                    this@CustomUriHandlerActivity,
                                    "Errors occurred during authentication:\n" +
                                        it.errors.joinToString(separator = "\n"),
                                )
                            }
                        }

                        viewModel.clearAction()
                        finish()
                    }
                }
            }
        }
    }
}
