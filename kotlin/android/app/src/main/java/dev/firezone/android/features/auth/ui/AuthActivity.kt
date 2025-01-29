/* Licensed under Apache 2.0 (C) 2024 Firezone, Inc. */
package dev.firezone.android.features.auth.ui

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.viewModels
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.R
import dev.firezone.android.core.presentation.MainActivity
import dev.firezone.android.databinding.ActivityAuthBinding

@AndroidEntryPoint
class AuthActivity : AppCompatActivity(R.layout.activity_auth) {
    private lateinit var binding: ActivityAuthBinding
    private val viewModel: AuthViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityAuthBinding.inflate(layoutInflater)

        setupActionObservers()
    }

    override fun onResume() {
        super.onResume()

        viewModel.onActivityResume()
    }

    private fun setupActionObservers() {
        viewModel.actionLiveData.observe(this) { action ->
            when (action) {
                is AuthViewModel.ViewAction.LaunchAuthFlow -> setupWebView(action.url)
                is AuthViewModel.ViewAction.NavigateToSignIn -> {
                    navigateToSignIn()
                }
                is AuthViewModel.ViewAction.ShowError -> showError()
                else -> {}
            }
        }
    }

    // We can't close this webview because it's opened with ACTION_VIEW.
    // If we want more control over it we need to embed our own WebView which
    // has its own set of tradeoffs.
    private fun setupWebView(url: String) {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
        startActivity(intent)
    }

    private fun navigateToSignIn() {
        startActivity(
            Intent(this, MainActivity::class.java),
        )
        finish()
    }

    private fun showError() {
        AlertDialog
            .Builder(this)
            .setTitle(R.string.error_dialog_title)
            .setMessage(R.string.error_dialog_message)
            .setPositiveButton(
                R.string.error_dialog_button_text,
            ) { _, _ ->
                this@AuthActivity.finish()
            }.setIcon(R.drawable.ic_firezone_logo)
            .show()
    }
}
