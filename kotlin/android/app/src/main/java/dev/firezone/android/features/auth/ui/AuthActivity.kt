/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.features.auth.ui

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.widget.Toast
import androidx.activity.viewModels
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.browser.customtabs.CustomTabsIntent
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.R
import dev.firezone.android.core.presentation.MainActivity
import dev.firezone.android.databinding.ActivityAuthBinding
import dev.firezone.android.util.CustomTabsHelper
import java.lang.Exception

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

    private fun setupWebView(url: String) {
        if (CustomTabsHelper.checkIfChromeIsInstalled(this)) {
            val intent = CustomTabsIntent.Builder().build()
            val packageName = CustomTabsHelper.getPackageNameToUse(this)
            if (CustomTabsHelper.checkIfChromeAppIsDefault()) {
                if (packageName != null) {
                    intent.intent.setPackage(packageName)
                }
            } else {
                intent.intent.setPackage(CustomTabsHelper.STABLE_PACKAGE)
            }

            try {
                intent.launchUrl(this@AuthActivity, Uri.parse(url))
            } catch (e: Exception) {
                showChromeAppRequiredError()
            }
        } else {
            showChromeAppRequiredError()
        }
    }

    private fun showChromeAppRequiredError() {
        Toast.makeText(this, getString(R.string.signing_in_requires_chrome_browser), Toast.LENGTH_LONG).show()
        navigateToSignIn()
    }

    private fun navigateToSignIn() {
        startActivity(
            Intent(this, MainActivity::class.java),
        )
        finish()
    }

    private fun showError() {
        AlertDialog.Builder(this)
            .setTitle(R.string.error_dialog_title)
            .setMessage(R.string.error_dialog_message)
            .setPositiveButton(
                R.string.error_dialog_button_text,
            ) { _, _ ->
                this@AuthActivity.finish()
            }
            .setIcon(R.drawable.ic_firezone_logo)
            .show()
    }
}
