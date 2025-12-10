// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.settings.ui

import android.os.Bundle
import android.view.View
import android.view.inputmethod.EditorInfo
import android.widget.Toast
import androidx.appcompat.widget.TooltipCompat
import androidx.core.widget.doOnTextChanged
import androidx.fragment.app.Fragment
import androidx.fragment.app.activityViewModels
import dev.firezone.android.R
import dev.firezone.android.core.data.model.ManagedConfigStatus
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
                        setText(action.config.authUrl)
                    }

                    binding.etApiUrlInput.apply {
                        setText(action.config.apiUrl)
                    }

                    binding.etLogFilterInput.apply {
                        setText(action.config.logFilter)
                    }

                    applyManagedStatus(action.managedStatus)
                }
            }
        }
    }

    private fun applyManagedStatus(status: ManagedConfigStatus) {
        binding.apply {
            val tooltipMessage = getString(R.string.managed_setting_info_description)

            etAuthUrlInput.isEnabled = !status.isAuthUrlManaged
            etAuthUrlInput.isFocusable = !status.isAuthUrlManaged
            etAuthUrlInput.isClickable = !status.isAuthUrlManaged
            ilAuthUrlInput.isEnabled = !status.isAuthUrlManaged
            ilAuthUrlInput.isFocusable = !status.isAuthUrlManaged
            ilAuthUrlInput.isClickable = !status.isAuthUrlManaged
            setupInfoIcon(ivAuthUrlInfo, status.isAuthUrlManaged, tooltipMessage)

            etApiUrlInput.isEnabled = !status.isApiUrlManaged
            etApiUrlInput.isFocusable = !status.isApiUrlManaged
            etApiUrlInput.isClickable = !status.isApiUrlManaged
            ilApiUrlInput.isEnabled = !status.isApiUrlManaged
            ilApiUrlInput.isFocusable = !status.isApiUrlManaged
            ilApiUrlInput.isClickable = !status.isApiUrlManaged
            setupInfoIcon(ivApiUrlInfo, status.isApiUrlManaged, tooltipMessage)

            etLogFilterInput.isEnabled = !status.isLogFilterManaged
            etLogFilterInput.isFocusable = !status.isLogFilterManaged
            etLogFilterInput.isClickable = !status.isLogFilterManaged
            ilLogFilterInput.isEnabled = !status.isLogFilterManaged
            ilLogFilterInput.isFocusable = !status.isLogFilterManaged
            ilLogFilterInput.isClickable = !status.isLogFilterManaged
            setupInfoIcon(ivLogFilterInfo, status.isLogFilterManaged, tooltipMessage)
        }
    }

    private fun setupInfoIcon(
        infoIconView: View,
        isManaged: Boolean,
        tooltipMessage: String,
    ) {
        if (isManaged) {
            infoIconView.visibility = View.VISIBLE
            TooltipCompat.setTooltipText(infoIconView, tooltipMessage)

            infoIconView.setOnClickListener { v ->
                Toast.makeText(v.context, tooltipMessage, Toast.LENGTH_SHORT).show()
            }
        } else {
            infoIconView.visibility = View.GONE
            TooltipCompat.setTooltipText(infoIconView, null)
            infoIconView.setOnClickListener(null)
            infoIconView.setOnLongClickListener(null)
        }
    }

    override fun onDestroyView() {
        super.onDestroyView()
        _binding = null
    }
}
