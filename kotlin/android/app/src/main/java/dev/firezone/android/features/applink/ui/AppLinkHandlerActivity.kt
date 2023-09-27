/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.features.applink.ui

import android.content.Intent
import android.os.Bundle
import android.util.Log
import androidx.activity.viewModels
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.R
import dev.firezone.android.core.presentation.MainActivity
import dev.firezone.android.databinding.ActivityAppLinkHandlerBinding

@AndroidEntryPoint
class AppLinkHandlerActivity : AppCompatActivity(R.layout.activity_app_link_handler) {

    private lateinit var binding: ActivityAppLinkHandlerBinding
    private val viewModel: AppLinkViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityAppLinkHandlerBinding.inflate(layoutInflater)

        setupActionObservers()
        viewModel.parseAppLink(intent)
    }

    private fun setupActionObservers() {
        viewModel.actionLiveData.observe(this) { action ->
            when (action) {
                AppLinkViewModel.ViewAction.AuthFlowComplete -> {
                    // TODO: Continue starting the session showing sessionFragment
                    Log.d("AppLinkHandlerActivity", "AuthFlowComplete")

                    val intent = Intent(this@AppLinkHandlerActivity, MainActivity::class.java)
                    this@AppLinkHandlerActivity.startActivity(intent)
                    this@AppLinkHandlerActivity.finish()
                }
                AppLinkViewModel.ViewAction.ShowError -> showError()
                else -> {
                    Log.d("AppLinkHandlerActivity", "Unhandled action: $action")
                }
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
                this@AppLinkHandlerActivity.finish()
            }
            .setIcon(R.drawable.ic_firezone_logo)
            .show()
    }
}
