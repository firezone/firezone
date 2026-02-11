// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.settings.ui

import android.os.Bundle
import androidx.activity.viewModels
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.fragment.app.Fragment
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import androidx.viewpager2.adapter.FragmentStateAdapter
import com.google.android.material.tabs.TabLayoutMediator
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.R
import dev.firezone.android.databinding.ActivitySettingsBinding
import kotlinx.coroutines.launch

@AndroidEntryPoint
internal class SettingsActivity : AppCompatActivity() {
    private lateinit var binding: ActivitySettingsBinding
    private val viewModel: SettingsViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivitySettingsBinding.inflate(layoutInflater)
        setContentView(binding.root)

        setupViews()
        setupStateObservers()

        viewModel.populateFieldsFromConfig()
        viewModel.deleteLogZip(this@SettingsActivity)
    }

    private fun setupViews() {
        val adapter = SettingsPagerAdapter(this)

        with(binding) {
            viewPager.adapter = adapter

            TabLayoutMediator(tabLayout, viewPager) { tab, position ->
                when (position) {
                    0 -> {
                        tab.setIcon(R.drawable.rounded_discover_tune_black_24dp)
                        tab.setText("General")
                    }

                    1 -> {
                        tab.setIcon(R.drawable.rounded_settings_black_24dp)
                        tab.setText("Advanced")
                    }

                    2 -> {
                        tab.setIcon(R.drawable.rounded_description_black_24dp)
                        tab.setText("Logs")
                    }

                    else -> {
                        throw IllegalArgumentException("Invalid tab position: $position")
                    }
                }
            }.attach()

            val isUserSignedIn = intent.getBooleanExtra("isUserSignedIn", false)
            if (isUserSignedIn) {
                btSaveSettings.setOnClickListener {
                    showSaveWarningDialog()
                }
            } else {
                btSaveSettings.setOnClickListener {
                    viewModel.onSaveSettingsCompleted()
                }
            }

            btCancel.setOnClickListener {
                viewModel.onCancel()
            }
        }
    }

    private fun setupStateObservers() {
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                viewModel.uiState.collect { uiState ->
                    with(binding) {
                        btSaveSettings.isEnabled = uiState.isSaveButtonEnabled
                    }
                }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        viewModel.onViewResume(this@SettingsActivity)
    }

    private fun showSaveWarningDialog() {
        AlertDialog.Builder(this).apply {
            setTitle("Warning")
            setMessage("Some changed settings will not be applied until you sign out and sign back in.")
            setPositiveButton("Okay") { _, _ ->
                viewModel.onSaveSettingsCompleted()
            }
            create().show()
        }
    }

    override fun onStop() {
        super.onStop()
        if (isFinishing) {
            viewModel.deleteLogZip(this@SettingsActivity)
        }
    }

    private inner class SettingsPagerAdapter(
        activity: FragmentActivity,
    ) : FragmentStateAdapter(activity) {
        override fun getItemCount(): Int = 3 // Three tabs

        override fun createFragment(position: Int): Fragment =
            when (position) {
                0 -> GeneralSettingsFragment()
                1 -> AdvancedSettingsFragment()
                2 -> LogSettingsFragment()
                else -> throw IllegalArgumentException("Invalid tab position: $position")
            }
    }
}
