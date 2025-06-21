/* Licensed under Apache 2.0 (C) 2024 Firezone, Inc. */
package dev.firezone.android.features.signin.ui

import android.content.Context
import android.content.Intent
import android.content.RestrictionsManager
import android.os.Bundle
import android.util.Log
import androidx.activity.viewModels
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.core.data.Repository
import dev.firezone.android.databinding.ActivitySignInBinding
import dev.firezone.android.features.auth.ui.AuthActivity
import dev.firezone.android.features.permission.vpn.ui.VpnPermissionActivity
import dev.firezone.android.features.session.ui.SessionActivity
import dev.firezone.android.features.settings.ui.SettingsActivity
import kotlinx.coroutines.launch
import javax.inject.Inject

@AndroidEntryPoint
internal class SignInActivity : AppCompatActivity() {
    private lateinit var binding: ActivitySignInBinding
    private val viewModel: SignInViewModel by viewModels()
    private var isInitialLaunch: Boolean = true;

    @Inject
    lateinit var repository: Repository

    override fun onCreate(savedInstanceState: Bundle?) {
        Log.d(TAG, "onCreate")

        super.onCreate(savedInstanceState)
        binding = ActivitySignInBinding.inflate(layoutInflater)
        setContentView(binding.root)

        setupActionObservers()
        setupButtonListener()
    }

    override fun onResume() {
        super.onResume()

        applyManagedConfigurations()

        viewModel.checkTunnelState(this, isInitialLaunch)

        isInitialLaunch = false;
    }

    private fun setupActionObservers() {
        viewModel.actionLiveData.observe(this) { action ->
            when (action) {
                SignInViewModel.ViewAction.NavigateToVpnPermission ->
                    startActivity(Intent(this, VpnPermissionActivity::class.java))
                SignInViewModel.ViewAction.NavigateToSettings ->
                    startActivity(Intent(this, SettingsActivity::class.java))
                SignInViewModel.ViewAction.NavigateToSession ->
                    startActivity(
                        Intent(this, SessionActivity::class.java).apply {
                            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
                        },
                    )
            }
        }
    }

    private fun setupButtonListener() {
        val authActivity =
            Intent(
                this,
                AuthActivity::class.java,
            )
        val settingsActivity = Intent(this, SettingsActivity::class.java)
        settingsActivity.putExtra("isUserSignedIn", true)

        with(binding) {
            btSignIn.setOnClickListener {
                startActivity(
                    authActivity,
                )
                finish()
            }
            btSettings.setOnClickListener {
                startActivity(settingsActivity)
            }
        }
    }

    private fun applyManagedConfigurations() {
        val restrictionsManager = getSystemService(Context.RESTRICTIONS_SERVICE) as RestrictionsManager
        val appRestrictions: Bundle = restrictionsManager.applicationRestrictions
        lifecycleScope.launch {
            repository.saveManagedConfiguration(appRestrictions).collect {}
        }
    }

    companion object {
        private const val TAG: String = "SignInActivity"
    }
}
