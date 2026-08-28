// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.auth.ui

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.viewModels
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.browser.customtabs.CustomTabsIntent
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.R
import dev.firezone.android.core.Log
import dev.firezone.android.core.presentation.MainActivity
import dev.firezone.android.databinding.ActivityAuthBinding
import kotlinx.coroutines.launch

@AndroidEntryPoint
class AuthActivity : AppCompatActivity(R.layout.activity_auth) {
    private lateinit var binding: ActivityAuthBinding
    private val viewModel: AuthViewModel by viewModels()
    private var browserState = AuthBrowserState.NOT_STARTED

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityAuthBinding.inflate(layoutInflater)
        browserState = AuthBrowserState.restore(savedInstanceState?.getString(BROWSER_STATE_KEY))

        setupActionObservers()

        if (browserState == AuthBrowserState.UNAVAILABLE) {
            showBrowserRequiredError()
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putString(BROWSER_STATE_KEY, browserState.name)
        super.onSaveInstanceState(outState)
    }

    override fun onResume() {
        super.onResume()

        when (browserState.resumeAction()) {
            AuthBrowserState.ResumeAction.START_AUTH_FLOW -> viewModel.onActivityResume()
            AuthBrowserState.ResumeAction.NAVIGATE_TO_SIGN_IN -> navigateToSignIn()
            AuthBrowserState.ResumeAction.NONE -> Unit
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
        if (browserState != AuthBrowserState.NOT_STARTED) {
            return
        }

        val url = Uri.parse(url)

        // Try to use Custom Tabs with the default browser first
        try {
            launchCustomTabsIntent(url)
            browserState = AuthBrowserState.LAUNCHED
            return
        } catch (e: ActivityNotFoundException) {
            Log.d(TAG, "CustomTabs don't appear to be available, falling back to ACTION_VIEW intent")
        }

        // Fallback to default browser if Custom Tabs unavailable
        try {
            launchActionViewIntent(url)
            browserState = AuthBrowserState.LAUNCHED
        } catch (e: ActivityNotFoundException) {
            browserState = AuthBrowserState.UNAVAILABLE
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
        private const val BROWSER_STATE_KEY = "browserState"
        private const val TAG = "AuthActivity"
    }
}
