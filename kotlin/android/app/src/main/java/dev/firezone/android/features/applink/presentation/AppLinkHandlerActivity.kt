package dev.firezone.android.features.applink.presentation

import androidx.appcompat.app.AppCompatActivity
import android.os.Bundle
import android.util.Log
import androidx.activity.viewModels
import androidx.appcompat.app.AlertDialog
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.R
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
                is AppLinkViewAction.AuthFlowComplete -> {
                    // Continue with onboarding
                    Log.d("AppLinkHandlerActivity", "AuthFlowComplete")
                }
                is AppLinkViewAction.ShowError -> showError()
                else -> {}
            }
        }
    }

    private fun showError() {
        AlertDialog.Builder(this)
            .setTitle(R.string.error_dialog_title)
            .setMessage(R.string.error_dialog_message)
            .setPositiveButton(
                R.string.error_dialog_button_text
            ) { _, _ ->
                this@AppLinkHandlerActivity.finish()
            }
            .setIcon(R.drawable.ic_firezone_logo)
            .show()
    }
}
