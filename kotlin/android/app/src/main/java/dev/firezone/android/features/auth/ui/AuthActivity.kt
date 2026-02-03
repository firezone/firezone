// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.auth.ui

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.util.Log
import androidx.activity.viewModels
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.browser.customtabs.CustomTabsIntent
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.R
import dev.firezone.android.core.presentation.MainActivity
import dev.firezone.android.databinding.ActivityAuthBinding
import kotlinx.coroutines.launch

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
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                viewModel.actionStateFlow.collect { action ->
                    action?.let {
                        viewModel.clearAction()
                        when (it) {
                            is AuthViewModel.ViewAction.LaunchAuthFlow -> setupWebView(it.url)
                        }
                    }
                }
            }
        }
    }

    private fun setupWebView(url: String) {
        hasLaunchedCustomTab = true

        val url = Uri.parse(url)

        // Try to use Custom Tabs with the default browser first
        try {
            launchCustomTabsIntent(url)
            return
        } catch (e: ActivityNotFoundException) {
            Log.d(TAG, "CustomTabs don't appear to be available, falling back to ACTION_VIEW intent")
        }

        // Fallback to default browser if Custom Tabs unavailable
        try {
            launchActionViewIntent(url)
        } catch (e: ActivityNotFoundException) {
            showBrowserRequiredError()
        }
    }

    private fun launchCustomTabsIntent(uri: Uri) {
        CustomTabsIntent
            .Builder()
            .setShowTitle(true)
            .build()
            .launchUrl(this, uri)
    }

    private fun launchActionViewIntent(uri: Uri) {
        val intent = Intent(Intent.ACTION_VIEW, uri)
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        intent.addCategory(Intent.CATEGORY_BROWSABLE)
        startActivity(intent)
    }

    private fun navigateToSignIn() {
        startActivity(
            Intent(this, MainActivity::class.java),
        )
        finish()
    }

    private fun showBrowserRequiredError() {
        AlertDialog
            .Builder(this)
            .setTitle(R.string.error_dialog_title)
            .setMessage(R.string.error_dialog_message_browser_required)
            .setPositiveButton(
                R.string.error_dialog_button_text,
            ) { _, _ ->
                this@AuthActivity.finish()
            }.setIcon(R.drawable.ic_firezone_logo)
            .show()
    }

    companion object {
        private const val TAG = "AuthActivity"
    }
}
