// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.settings.ui

import android.os.Bundle
import android.view.View
import androidx.fragment.app.Fragment
import androidx.fragment.app.activityViewModels
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import dev.firezone.android.R
import dev.firezone.android.databinding.FragmentSettingsLogsBinding
import kotlinx.coroutines.launch

class LogSettingsFragment : Fragment(R.layout.fragment_settings_logs) {
    private var _binding: FragmentSettingsLogsBinding? = null
    val binding: FragmentSettingsLogsBinding get() = _binding!!
    private val viewModel: SettingsViewModel by activityViewModels()

    override fun onViewCreated(
        view: View,
        savedInstanceState: Bundle?,
    ) {
        super.onViewCreated(view, savedInstanceState)
        _binding = FragmentSettingsLogsBinding.bind(view)

        setupViews()
        setupStateObservers()
    }

    private fun setupViews() {
        binding.apply {
            btClearLog.setOnClickListener {
                viewModel.deleteLogDirectory(requireContext())
            }
            btShareLog.setOnClickListener {
                viewModel.createLogZip(requireContext())
            }
        }
    }

    private fun setupStateObservers() {
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                viewModel.uiState.collect { uiState ->
                    with(binding) {
                        val hasLogs = uiState.logSizeBytes > 0
                        btShareLog.isEnabled = hasLogs
                        btClearLog.isEnabled = hasLogs
                        val logSize = "${uiState.logSizeBytes / 1000000L} MB"
                        tvLogDirectorySize.text = getString(R.string.log_directory_size, logSize)
                    }
                }
            }
        }
    }
}
