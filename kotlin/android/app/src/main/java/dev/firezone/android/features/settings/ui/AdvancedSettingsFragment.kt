/* Licensed under Apache 2.0 (C) 2024 Firezone, Inc. */
package dev.firezone.android.features.settings.ui

import android.os.Bundle
import android.view.View
import android.view.inputmethod.EditorInfo
import androidx.core.widget.doOnTextChanged
import androidx.fragment.app.Fragment
import androidx.fragment.app.activityViewModels
import dev.firezone.android.R
import dev.firezone.android.databinding.FragmentSettingsAdvancedBinding

class AdvancedSettingsFragment : Fragment(R.layout.fragment_settings_advanced) {
    private var _binding: FragmentSettingsAdvancedBinding? = null

    val binding get() = _binding!!

    private val viewModel: SettingsViewModel by activityViewModels()

    override fun onViewCreated(
        view: View,
        savedInstanceState: Bundle?,
    ) {
        super.onViewCreated(view, savedInstanceState)
        _binding = FragmentSettingsAdvancedBinding.bind(view)

        setupViews()
        setupActionObservers()
    }

    private fun setupViews() {
        binding.apply {
            etAuthUrlInput.apply {
                imeOptions = EditorInfo.IME_ACTION_DONE
                setOnClickListener { isCursorVisible = true }
                doOnTextChanged { text, _, _, _ ->
                    viewModel.onValidateAuthUrl(text.toString())
                }
            }

            etApiUrlInput.apply {
                imeOptions = EditorInfo.IME_ACTION_DONE
                setOnClickListener { isCursorVisible = true }
                doOnTextChanged { text, _, _, _ ->
                    viewModel.onValidateApiUrl(text.toString())
                }
            }

            etLogFilterInput.apply {
                imeOptions = EditorInfo.IME_ACTION_DONE
                setOnClickListener { isCursorVisible = true }
                doOnTextChanged { text, _, _, _ ->
                    viewModel.onValidateLogFilter(text.toString())
                }
            }

            btResetDefaults.setOnClickListener {
                viewModel.resetSettingsToDefaults()
            }
        }
    }

    private fun setupActionObservers() {
        viewModel.actionLiveData.observe(viewLifecycleOwner) { action ->
            when (action) {
                is SettingsViewModel.ViewAction.NavigateBack ->
                    requireActivity().finish()

                is SettingsViewModel.ViewAction.FillSettings -> {
                    binding.etAuthUrlInput.apply {
                        setText(action.userConfig.authUrl)
                    }
                    binding.etApiUrlInput.apply {
                        setText(action.userConfig.apiUrl)
                    }
                    binding.etLogFilterInput.apply {
                        setText(action.userConfig.logFilter)
                    }
                }
            }
        }
    }

    override fun onDestroyView() {
        super.onDestroyView()
        _binding = null
    }
}
