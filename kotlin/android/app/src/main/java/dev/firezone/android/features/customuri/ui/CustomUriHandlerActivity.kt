/* Licensed under Apache 2.0 (C) 2024 Firezone, Inc. */
package dev.firezone.android.features.customuri.ui

import android.content.Intent
import android.os.Bundle
import androidx.activity.viewModels
import androidx.appcompat.app.AppCompatActivity
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.R
import dev.firezone.android.core.presentation.MainActivity
import dev.firezone.android.databinding.ActivityCustomUriHandlerBinding
import dev.firezone.android.tunnel.TunnelService

@AndroidEntryPoint
class CustomUriHandlerActivity : AppCompatActivity(R.layout.activity_custom_uri_handler) {
    private lateinit var binding: ActivityCustomUriHandlerBinding
    private val viewModel: CustomUriViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityCustomUriHandlerBinding.inflate(layoutInflater)

        setupActionObservers()
        viewModel.parseCustomUri(intent)
    }

    private fun setupActionObservers() {
        viewModel.actionLiveData.observe(this) { action ->
            when (action) {
                CustomUriViewModel.ViewAction.AuthFlowComplete -> {
                    TunnelService.start(this@CustomUriHandlerActivity)
                    startActivity(
                        Intent(this, MainActivity::class.java),
                    )
                }
                else -> {
                    throw IllegalStateException("Unknown action: $action")
                }
            }

            finish()
        }
    }
}
