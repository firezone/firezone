// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.core.presentation

import android.content.Context
import android.content.RestrictionsManager
import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.appcompat.app.AppCompatActivity
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.lifecycle.lifecycleScope
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.core.DebugOverrides
import dev.firezone.android.core.data.Repository
import dev.firezone.android.ui.AppShell
import dev.firezone.android.ui.theme.FirezoneTheme
import kotlinx.coroutines.launch
import javax.inject.Inject

@AndroidEntryPoint
internal class MainActivity : AppCompatActivity() {
    @Inject
    internal lateinit var repository: Repository

    // Read on every frame the system splash considers dismissing, which is why it is a plain field
    // rather than something the composition observes.
    private var hasDestination = false

    override fun onCreate(savedInstanceState: Bundle?) {
        // Before the screens that read them exist.
        DebugOverrides.configure(this)

        // The system splash stands in for a screen of our own: holding it until the launch knows
        // where it is going is what keeps the app from drawing a second one behind it.
        installSplashScreen().setKeepOnScreenCondition { !hasDestination }

        super.onCreate(savedInstanceState)

        setContent {
            FirezoneTheme {
                AppShell(
                    onNotificationPermissionRequested = repository::setNotificationPermissionRequested,
                    onSignInLaunched = ::finish,
                    onLaunchResolved = { hasDestination = true },
                )
            }
        }
    }

    override fun onResume() {
        super.onResume()

        // Apply managed configurations when the app resumes since it's not guaranteed
        // the TunnelService is running when the app starts or is backgrounded.
        applyManagedConfigurations()
    }

    private fun applyManagedConfigurations() {
        val restrictionsManager = getSystemService(Context.RESTRICTIONS_SERVICE) as RestrictionsManager
        val appRestrictions: Bundle = restrictionsManager.applicationRestrictions
        lifecycleScope.launch {
            repository.saveManagedConfiguration(appRestrictions).collect {}
        }
    }
}
