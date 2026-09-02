// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.auth.ui

import android.content.ActivityNotFoundException
import android.net.Uri
import android.os.Bundle
import androidx.activity.viewModels
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.browser.auth.AuthTabIntent
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.R
import dev.firezone.android.core.Log
import dev.firezone.android.features.auth.AUTH_CALLBACK_SCHEME
import dev.firezone.android.tunnel.TunnelService
import kotlinx.coroutines.launch

@AndroidEntryPoint
class AuthActivity : AppCompatActivity(R.layout.activity_auth) {
    private val viewModel: AuthViewModel by viewModels()
    private val authTabLauncher =
        AuthTabIntent.registerActivityResultLauncher(this) { result ->
            handleAuthResult(result)
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        setupActionObservers()
        if (savedInstanceState == null) {
            viewModel.startAuthFlow()
        } else if (!viewModel.canRestoreAuthFlow()) {
            returnToSignIn()
        }
    }

    private fun setupActionObservers() {
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                viewModel.actionStateFlow.collect { action ->
                    action?.let {
                        viewModel.clearAction()
                        when (it) {
                            is AuthViewModel.ViewAction.LaunchAuthFlow -> launchAuthTab(it.url)
                            AuthViewModel.ViewAction.AuthFlowComplete -> completeAuthFlow()
                            is AuthViewModel.ViewAction.AuthFlowError -> failAuthFlow(it.errors)
                        }
                    }
                }
            }
        }
    }

    private fun launchAuthTab(url: String) {
        try {
            AuthTabIntent
                .Builder()
                .build()
                .launch(
                    authTabLauncher,
                    Uri.parse(url),
                    AUTH_CALLBACK_SCHEME,
                )
        } catch (e: ActivityNotFoundException) {
            Log.d(TAG, "No browser is available to launch the authentication flow")
            viewModel.cancelAuthFlow()
            showBrowserRequiredError()
        }
    }

    private fun handleAuthResult(result: AuthTabIntent.AuthResult) {
        when (result.resultCode) {
            AuthTabIntent.RESULT_OK -> viewModel.processAuthCallback(result.resultUri)
            AuthTabIntent.RESULT_CANCELED -> returnToSignIn()
            else -> {
                viewModel.cancelAuthFlow()
                failAuthFlow(listOf("Authentication browser could not complete the redirect"))
            }
        }
    }

    private fun completeAuthFlow() {
        TunnelService.start(this)
        startActivity(mainActivityHandoffIntent(this))
        finish()
    }

    private fun returnToSignIn() {
        startActivity(mainActivityReturnIntent(this))
        finish()
    }

    private fun failAuthFlow(errors: Iterable<String>) {
        notifyAuthError(
            this,
            "Errors occurred during authentication:\n${errors.joinToString(separator = "\n")}",
        )
        startActivity(mainActivityHandoffIntent(this))
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
                returnToSignIn()
            }.setOnCancelListener {
                returnToSignIn()
            }.setIcon(R.drawable.ic_firezone_logo)
            .show()
    }

    companion object {
        private const val TAG = "AuthActivity"
    }
}
