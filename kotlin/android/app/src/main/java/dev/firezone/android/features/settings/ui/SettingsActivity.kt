/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.features.settings.ui

import android.os.Bundle
import android.view.inputmethod.EditorInfo
import androidx.activity.viewModels
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.isVisible
import androidx.core.widget.doOnTextChanged
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import dagger.hilt.android.AndroidEntryPoint
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
        setupActionObservers()
        setupButtonListeners()

        viewModel.populateFieldsFromConfig()
    }

    override fun onResume() {
        super.onResume()
        viewModel.onViewResume(this@SettingsActivity)
    }

    private fun setupStateObservers() {
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                viewModel.uiState.collect { uiState ->
                    with(binding) {
                        btSaveSettings.isEnabled = uiState.isSaveButtonEnabled
                        btShareLog.isVisible = uiState.logSize > 0
                    }
                }
            }
        }
    }

    private fun setupActionObservers() {
        viewModel.actionLiveData.observe(this@SettingsActivity) { action ->
            when (action) {
                is SettingsViewModel.ViewAction.NavigateBack ->
                    finish()
                is SettingsViewModel.ViewAction.FillSettings -> {
                    binding.etAuthBaseUrlInput.apply {
                        setText(action.authBaseUrl)
                    }
                    binding.etApiUrlInput.apply {
                        setText(action.apiUrl)
                    }
                    binding.etLogFilterInput.apply {
                        setText(action.logFilter)
                    }
                }
            }
        }
    }

    private fun setupViews() {

        binding.etAuthBaseUrlInput.apply {
            imeOptions = EditorInfo.IME_ACTION_DONE
            setOnClickListener { isCursorVisible = true }
            doOnTextChanged { authBaseUrl, _, _, _ ->
                viewModel.onValidateAuthBaseUrl(authBaseUrl.toString())
            }
        }

        binding.etApiUrlInput.apply {
            imeOptions = EditorInfo.IME_ACTION_DONE
            setOnClickListener { isCursorVisible = true }
            doOnTextChanged { apiUrl, _, _, _ ->
                viewModel.onValidateApiUrl(apiUrl.toString())
            }
        }

        binding.etLogFilterInput.apply {
            imeOptions = EditorInfo.IME_ACTION_DONE
            setOnClickListener { isCursorVisible = true }
            doOnTextChanged { logFilter, _, _, _ ->
                viewModel.onValidateLogFilter(logFilter.toString())
            }
        }
    }

    private fun setupButtonListeners() {
        binding.btShareLog.apply {
            setOnClickListener {
                viewModel.createLogZip(this@SettingsActivity)
            }
        }

        binding.btSaveSettings.setOnClickListener {
            viewModel.onSaveSettingsCompleted()
        }

        binding.btCancel.setOnClickListener {
            viewModel.onCancel()
        }
    }
}
