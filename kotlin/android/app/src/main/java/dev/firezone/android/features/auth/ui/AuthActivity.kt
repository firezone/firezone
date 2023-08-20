package dev.firezone.android.features.auth.ui

import android.util.Log
import android.net.Uri
import androidx.appcompat.app.AppCompatActivity
import android.os.Bundle
import androidx.activity.viewModels
import androidx.appcompat.app.AlertDialog
import androidx.browser.customtabs.CustomTabsIntent
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.R
import dev.firezone.android.util.CustomTabsHelper
import dev.firezone.android.databinding.ActivityAuthBinding

@AndroidEntryPoint
class AuthActivity : AppCompatActivity(R.layout.activity_auth) {

    private lateinit var binding: ActivityAuthBinding
    private val viewModel: AuthViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityAuthBinding.inflate(layoutInflater)

        setupActionObservers()

        viewModel.startAuthFlow()
    }

    private fun setupActionObservers() {
        viewModel.actionLiveData.observe(this) { action ->
            Log.d("AuthActivity", "setupActionObservers: $action")
            when (action) {
                is AuthViewModel.ViewAction.LaunchAuthFlow -> setupWebView(action.url)
                is AuthViewModel.ViewAction.ShowError -> showError()
                else -> {}
            }
        }
    }

    private fun setupWebView(url: String) {
        val intent = CustomTabsIntent.Builder().build()
        val packageName = CustomTabsHelper.getPackageNameToUse(this@AuthActivity)
        intent.intent.setPackage(packageName)
        intent.launchUrl(this@AuthActivity, Uri.parse(url))
    }

    private fun showError() {
        AlertDialog.Builder(this)
            .setTitle(R.string.error_dialog_title)
            .setMessage(R.string.error_dialog_message)
            .setPositiveButton(
                R.string.error_dialog_button_text
            ) { _, _ ->
                this@AuthActivity.finish()
            }
            .setIcon(R.drawable.ic_firezone_logo)
            .show()
    }
}
