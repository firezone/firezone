/* Licensed under Apache 2.0 (C) 2024 Firezone, Inc. */
package dev.firezone.android.features.auth.ui

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.viewModels
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.browser.customtabs.CustomTabsIntent
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.R
import dev.firezone.android.core.presentation.MainActivity
import dev.firezone.android.databinding.ActivityAuthBinding

@AndroidEntryPoint
class AuthActivity : AppCompatActivity(R.layout.activity_auth) {
    private lateinit var binding: ActivityAuthBinding
    private val viewModel: AuthViewModel by viewModels()
    private var hasLaunchedCustomTab = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityAuthBinding.inflate(layoutInflater)

        setupActionObservers()
    }

    override fun onResume() {
        super.onResume()

        if (hasLaunchedCustomTab) {
            // User returned from Custom Tab without completing auth, navigate back to main app
            navigateToSignIn()
        } else {
            viewModel.onActivityResume()
        }
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

    private fun setupWebView(url: String) {
        hasLaunchedCustomTab = true
        val customTabsIntent =
            CustomTabsIntent
                .Builder()
                .setShowTitle(true)
                .build()
        val url = Uri.parse(url)

        // Try to use Custom Tabs with the default browser first
        try {
            customTabsIntent.launchUrl(this, url)
        } catch (e: ActivityNotFoundException) {
            // Fallback to default browser if Custom Tabs unavailable
            val intent = Intent(Intent.ACTION_VIEW, url)
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
        }
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
