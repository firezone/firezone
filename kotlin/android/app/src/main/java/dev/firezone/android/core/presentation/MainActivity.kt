// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.core.presentation

import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.R
import dev.firezone.android.core.data.ManagedConfigurationSource
import kotlinx.coroutines.launch
import javax.inject.Inject

@AndroidEntryPoint
internal class MainActivity : AppCompatActivity(R.layout.activity_main) {
    @Inject
    internal lateinit var managedConfigurationSource: ManagedConfigurationSource

    override fun onResume() {
        super.onResume()

        lifecycleScope.launch { managedConfigurationSource.refresh() }
    }
}
