/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.features.settings.ui

import android.os.Bundle
import android.util.Log
import android.view.View
import android.view.inputmethod.EditorInfo
import androidx.core.widget.doOnTextChanged
import androidx.fragment.app.Fragment
import androidx.fragment.app.viewModels
import androidx.navigation.fragment.findNavController
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.R
import dev.firezone.android.databinding.FragmentSettingsBinding

@AndroidEntryPoint
internal class SettingsFragment : Fragment(R.layout.fragment_settings) {
    private lateinit var binding: FragmentSettingsBinding
    private val viewModel: SettingsViewModel by viewModels()

    override fun onViewCreated(
        view: View,
        savedInstanceState: Bundle?,
    ) {
        super.onViewCreated(view, savedInstanceState)
        binding = FragmentSettingsBinding.bind(view)

        setupViews()
        setupStateObservers()
        setupActionObservers()
        setupButtonListeners()

        viewModel.populateFieldsFromConfig()
    }

    private fun setupStateObservers() {
        viewModel.stateLiveData.observe(viewLifecycleOwner) { state ->
            with(binding) {
                Log.d("SettingsFragment", "state: $state")
                btSaveSettings.isEnabled = state.isSaveButtonEnabled
            }
        }
    }

    private fun setupActionObservers() {
        viewModel.actionLiveData.observe(viewLifecycleOwner) { action ->
            when (action) {
                is SettingsViewModel.ViewAction.NavigateToSignIn ->
                    findNavController().navigate(
                        R.id.signInFragment,
                    )
                is SettingsViewModel.ViewAction.FillSettings -> {
                    Log.d("SettingsFragment", "action: $action")
                    binding.etAccountIdInput.apply {
                        setText(action.accountId)
                    }
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
        binding.etAccountIdInput.apply {
            imeOptions = EditorInfo.IME_ACTION_DONE
            setOnClickListener { isCursorVisible = true }
            doOnTextChanged { accountId, _, _, _ ->
                viewModel.onValidateAccountId(accountId.toString())
            }
        }

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
        binding.btSaveSettings.setOnClickListener {
            viewModel.onSaveSettingsCompleted()
        }

        binding.btCancel.setOnClickListener {
            viewModel.onCancel()
        }
    }
}
