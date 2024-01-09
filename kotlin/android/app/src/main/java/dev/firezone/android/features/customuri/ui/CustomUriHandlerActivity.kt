/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.features.customuri.ui

import android.content.Intent
import android.os.Bundle
import androidx.activity.viewModels
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.R
import dev.firezone.android.core.presentation.MainActivity
import dev.firezone.android.databinding.ActivityCustomUriHandlerBinding

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
                    startActivity(
                        Intent(this@CustomUriHandlerActivity, MainActivity::class.java).apply {
                            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
                        },
                    )
                    finish()
                }
                CustomUriViewModel.ViewAction.ShowError -> showError()
            }
        }
    }

    private fun showError() {
        AlertDialog.Builder(this)
            .setTitle(R.string.error_dialog_title)
            .setMessage(R.string.error_dialog_message)
            .setPositiveButton(
                R.string.error_dialog_button_text,
            ) { _, _ ->
                this@CustomUriHandlerActivity.finish()
            }
            .setIcon(R.drawable.ic_firezone_logo)
            .show()
    }
}
