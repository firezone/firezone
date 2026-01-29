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
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import dev.firezone.android.R
import dev.firezone.android.core.data.model.ManagedConfigStatus
import dev.firezone.android.databinding.FragmentSettingsGeneralBinding
import kotlinx.coroutines.launch

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
            switchStartOnLogin.apply {
                setOnCheckedChangeListener { _, isChecked ->
                    viewModel.onStartOnLoginChanged(isChecked)
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
        viewLifecycleOwner.lifecycleScope.launch {
            viewLifecycleOwner.repeatOnLifecycle(Lifecycle.State.STARTED) {
                viewModel.actionStateFlow.collect { action ->
                    action?.let {
                        viewModel.clearAction()
                        when (it) {
                            is SettingsViewModel.ViewAction.NavigateBack ->
                                requireActivity().finish()

                            is SettingsViewModel.ViewAction.FillSettings -> {
                                binding.etAccountSlugInput.apply {
                                    setText(it.config.accountSlug)
                                }

                                binding.switchStartOnLogin.apply {
                                    isChecked = it.config.startOnLogin
                                }

                                binding.switchConnectOnStart.apply {
                                    isChecked = it.config.connectOnStart
                                }

                                applyManagedStatus(it.managedStatus)
                            }
                        }
                    }
                }
            }
        }
    }

    private fun applyManagedStatus(status: ManagedConfigStatus) {
        binding.apply {
            val tooltipMessage = getString(R.string.managed_setting_info_description)

            etAccountSlugInput.isEnabled = !status.isAccountSlugManaged
            etAccountSlugInput.isFocusable = !status.isAccountSlugManaged
            etAccountSlugInput.isClickable = !status.isAccountSlugManaged
            ilAccountSlugInput.isEnabled = !status.isAccountSlugManaged
            setupInfoIcon(ivAccountSlugInfo, status.isAccountSlugManaged, tooltipMessage)

            switchStartOnLogin.isEnabled = !status.isStartOnLoginManaged
            switchStartOnLogin.isFocusable = !status.isStartOnLoginManaged
            switchStartOnLogin.isClickable = !status.isStartOnLoginManaged
            setupTooltipForWrapper(flStartOnLoginWrapper, status.isStartOnLoginManaged, tooltipMessage)

            switchConnectOnStart.isEnabled = !status.isConnectOnStartManaged
            switchConnectOnStart.isFocusable = !status.isConnectOnStartManaged
            switchConnectOnStart.isClickable = !status.isConnectOnStartManaged
            setupTooltipForWrapper(flConnectOnStartWrapper, status.isConnectOnStartManaged, tooltipMessage)
        }
    }

    private fun setupTooltipForWrapper(
        view: View,
        isManaged: Boolean,
        tooltipMessage: String,
    ) {
        if (isManaged) {
            view.isClickable = true
            view.isFocusable = true
            TooltipCompat.setTooltipText(view, tooltipMessage)

            view.setOnClickListener { v ->
                Toast.makeText(v.context, tooltipMessage, Toast.LENGTH_SHORT).show()
            }
        } else {
            view.isClickable = false
            view.isFocusable = false
            TooltipCompat.setTooltipText(view, null)
            view.setOnLongClickListener(null)
            view.setOnClickListener(null)
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
