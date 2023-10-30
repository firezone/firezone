/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.features.settings.ui

import android.os.Bundle
import android.util.Log
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
        setupButtonListener()

        viewModel.getAccountId()
    }

    override fun onResume() {
        super.onResume()
        viewModel.onViewResume(this@SettingsActivity)
    }

    private fun setupStateObservers() {
        viewModel.stateLiveData.observe(this@SettingsActivity) { state ->
            with(binding) {
                btSave.isEnabled = state.isButtonEnabled
            }
        }

        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                viewModel.uiState.collect { uiState ->
                    binding.btSave.isVisible = uiState.logSize > 0
                }
            }
        }
    }

    private fun setupActionObservers() {
        viewModel.actionLiveData.observe(this@SettingsActivity) { action ->
            when (action) {
                is SettingsViewModel.ViewAction.NavigateBack ->
                    finish()
                is SettingsViewModel.ViewAction.FillAccountId -> {
                    binding.etInput.apply {
                        setText(action.value)
                        isCursorVisible = false
                    }
                }
            }
        }
    }

    private fun setupViews() {
        binding.ilUrlInput.apply {
            prefixText = SettingsViewModel.AUTH_URL
        }

        binding.btShareLog.apply {
            setOnClickListener {
                viewModel.createLogZip(this@SettingsActivity)
            }
        }

        binding.etInput.apply {
            imeOptions = EditorInfo.IME_ACTION_DONE
            setOnClickListener { isCursorVisible = true }
            doOnTextChanged { input, _, _, _ ->
                viewModel.onValidateInput(input.toString())
            }
            requestFocus()
        }

        binding.btSave.setOnClickListener {
            viewModel.onSaveSettingsCompleted()
        }
    }

    private fun setupButtonListener() {
    }
}
