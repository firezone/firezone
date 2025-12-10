// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.core.presentation

import android.content.Context
import android.content.RestrictionsManager
import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope // For launching coroutines
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.R
import dev.firezone.android.core.data.Repository
import kotlinx.coroutines.launch
import javax.inject.Inject

@AndroidEntryPoint
internal class MainActivity : AppCompatActivity(R.layout.activity_main) {
    @Inject
    lateinit var repository: Repository

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
