package dev.firezone.android.features.applink.ui

import androidx.appcompat.app.AppCompatActivity
import android.os.Bundle
import android.util.Log
import androidx.activity.viewModels
import androidx.appcompat.app.AlertDialog
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.BuildConfig
import dev.firezone.android.R
import dev.firezone.android.databinding.ActivityAppLinkHandlerBinding
import dev.firezone.android.features.session.backend.SessionManager
import dev.firezone.android.features.splash.ui.SplashFragmentDirections
import dev.firezone.android.tunnel.TunnelManager
import dev.firezone.android.tunnel.TunnelSession
import javax.inject.Inject

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
                R.string.error_dialog_button_text
            ) { _, _ ->
                this@AppLinkHandlerActivity.finish()
            }
            .setIcon(R.drawable.ic_firezone_logo)
            .show()
    }
}
