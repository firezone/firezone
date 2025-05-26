/* Licensed under Apache 2.0 (C) 2024 Firezone, Inc. */
package dev.firezone.android.features.settings.ui

import android.os.Bundle
import android.view.View
import android.view.inputmethod.EditorInfo
import androidx.core.widget.doOnTextChanged
import androidx.fragment.app.Fragment
import androidx.fragment.app.activityViewModels
import dev.firezone.android.R
import dev.firezone.android.databinding.FragmentSettingsGeneralBinding

class GeneralSettingsFragment : Fragment(R.layout.fragment_settings_general) {
    private var _binding: FragmentSettingsGeneralBinding? = null

    val binding get() = _binding!!

    private val viewModel: SettingsViewModel by activityViewModels()

    override fun onViewCreated(
        view: View,
        savedInstanceState: Bundle?,
    ) {
        super.onViewCreated(view, savedInstanceState)
        _binding = FragmentSettingsGeneralBinding.bind(view)

        setupViews()
        setupActionObservers()
    }

    private fun setupViews() {
        binding.apply {
            etAccountSlugInput.apply {
                imeOptions = EditorInfo.IME_ACTION_DONE
                setOnClickListener { isCursorVisible = true }
                doOnTextChanged { text, _, _, _ ->
                    viewModel.onValidateAccountSlug(text.toString())
                }
            }

            switchStartOnBoot.apply {
                setOnCheckedChangeListener { _, isChecked ->
                    viewModel.onStartOnBootChanged(isChecked)
                }
            }

            switchConnectOnStart.apply {
                setOnCheckedChangeListener { _, isChecked ->
                    viewModel.onConnectOnStartChanged(isChecked)
                }
            }
        }
    }

    private fun setupActionObservers() {
        viewModel.actionLiveData.observe(viewLifecycleOwner) { action ->
            when (action) {
                is SettingsViewModel.ViewAction.NavigateBack ->
                    requireActivity().finish()

                is SettingsViewModel.ViewAction.FillSettings -> {
                    binding.etAccountSlugInput.apply {
                        setText(action.userConfig.accountSlug)
                    }
                    binding.switchStartOnBoot.apply {
                        isChecked = action.userConfig.startOnBoot
                    }
                    binding.switchConnectOnStart.apply {
                        isChecked = action.userConfig.connectOnStart
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
