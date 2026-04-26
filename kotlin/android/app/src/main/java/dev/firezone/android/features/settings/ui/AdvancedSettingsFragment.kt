// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.settings.ui

import android.os.Bundle
import android.security.KeyChain
import android.view.View
import android.view.inputmethod.EditorInfo
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.widget.TooltipCompat
import androidx.core.widget.doOnTextChanged
import androidx.fragment.app.Fragment
import androidx.fragment.app.activityViewModels
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import dev.firezone.android.R
import dev.firezone.android.core.Log
import dev.firezone.android.core.data.model.ManagedConfigStatus
import dev.firezone.android.databinding.FragmentSettingsAdvancedBinding
import dev.firezone.android.tunnel.inspectDeviceTrustCertificate
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

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
        viewModel.refreshManagedConfigurationState()
        refreshDeviceTrustCertificateState()
    }

    override fun onResume() {
        super.onResume()
        viewModel.refreshManagedConfigurationState()
        refreshDeviceTrustCertificateState()
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
                refreshDeviceTrustCertificateState()
            }

            btSelectDeviceTrustCertificate.setOnClickListener {
                selectDeviceTrustCertificate()
            }

            btShowDeviceTrustCertificateDetails.setOnClickListener {
                showDeviceTrustDetailsDialog()
            }
        }
    }

    private fun setupActionObservers() {
        viewLifecycleOwner.lifecycleScope.launch {
            viewLifecycleOwner.repeatOnLifecycle(Lifecycle.State.STARTED) {
                launch {
                    viewModel.configStateFlow.collect { config ->
                        binding.etAuthUrlInput.setText(config.authUrl)
                        binding.etApiUrlInput.setText(config.apiUrl)
                        binding.etLogFilterInput.setText(config.logFilter)
                    }
                }

                launch {
                    viewModel.managedStatusStateFlow.collect { managedStatus ->
                        managedStatus?.let {
                            applyManagedStatus(it)
                        }
                    }
                }

                launch {
                    viewModel.actionStateFlow.collect { action ->
                        action?.let {
                            viewModel.clearAction()
                            when (it) {
                                is SettingsViewModel.ViewAction.NavigateBack -> {
                                    requireActivity().finish()
                                }
                            }
                        }
                    }
                }

                launch {
                    viewModel.deviceTrustCertificateStateFlow.collect { state ->
                        applyDeviceTrustCertificateState(state)
                    }
                }
            }
        }
    }

    private fun refreshDeviceTrustCertificateState() {
        viewLifecycleOwner.lifecycleScope.launch {
            val selectedAlias = viewModel.selectedDeviceTrustCertificateAlias()?.trim()?.takeIf { it.isNotEmpty() }
            val managedAlias = viewModel.managedDeviceTrustCertificateAlias()?.trim()?.takeIf { it.isNotEmpty() }
            val aliases =
                listOfNotNull(
                    selectedAlias,
                    managedAlias,
                    viewModel.conventionalDeviceTrustCertificateAlias(),
                ).distinct()

            val inspection =
                withContext(Dispatchers.IO) {
                    aliases.firstNotNullOfOrNull { alias ->
                        inspectDeviceTrustCertificate(requireContext(), alias)
                    }
                }

            val hasUnsavedAlias = viewModel.hasUnsavedDeviceTrustCertificateAlias()
            val managedAliasIsActive = managedAlias != null && selectedAlias == null

            if (inspection == null) {
                val statusMessage =
                    if (selectedAlias != null) {
                        getString(R.string.device_trust_selected_certificate_unavailable, selectedAlias)
                    } else if (managedAlias != null) {
                        getString(R.string.device_trust_managed_certificate_unavailable, managedAlias)
                    } else if (hasUnsavedAlias) {
                        getString(R.string.device_trust_status_cleared_pending_save)
                    } else {
                        getString(R.string.device_trust_status_not_selected)
                    }

                viewModel.onDeviceTrustCertificateInspectionUpdated(
                    SettingsViewModel.DeviceTrustCertificateUiState(
                        managedAlias = managedAlias,
                        statusMessage = statusMessage,
                        isSelectCertificateVisible = true,
                        hasExplicitAliasSelection = selectedAlias != null,
                    ),
                )
                return@launch
            }

            val statusMessage =
                when {
                    hasUnsavedAlias && selectedAlias == inspection.alias -> {
                        getString(R.string.device_trust_status_selected_pending_save)
                    }
                    managedAliasIsActive && inspection.alias == managedAlias && inspection.isUsable -> {
                        getString(R.string.device_trust_status_managed_selected)
                    }
                    managedAliasIsActive && inspection.alias == managedAlias -> {
                        getString(R.string.device_trust_status_managed_selected_but_unusable)
                    }
                    inspection.isUsable -> {
                        getString(R.string.device_trust_status_selected)
                    }
                    else -> {
                        getString(R.string.device_trust_status_selected_but_unusable)
                    }
                }

            viewModel.onDeviceTrustCertificateInspectionUpdated(
                SettingsViewModel.DeviceTrustCertificateUiState(
                    alias = inspection.alias,
                    managedAlias = managedAlias,
                    subjectCommonName = inspection.summary.commonName,
                    issuerCommonName = inspection.summary.issuerCommonName,
                    sha256 = inspection.summary.sha256,
                    isClientAuthCertificate = inspection.summary.hasClientAuthExtendedKeyUsage,
                    isPrivateKeyAccessible = inspection.hasPrivateKeyAccess,
                    isCurrentlyValid = inspection.isCurrentlyValid,
                    statusMessage = statusMessage,
                    isSelectCertificateVisible = true,
                    hasExplicitAliasSelection = selectedAlias != null,
                ),
            )
        }
    }

    private fun selectDeviceTrustCertificate() {
        val preferredAlias = viewModel.preferredDeviceTrustCertificateAlias()
        Log.d(
            TAG,
            "Opening Android KeyChain chooser for device trust. preferred_alias=$preferredAlias",
        )

        KeyChain.choosePrivateKeyAlias(
            requireActivity(),
            { alias ->
                requireActivity().runOnUiThread {
                    if (!isAdded || _binding == null) {
                        return@runOnUiThread
                    }
                    viewLifecycleOwner.lifecycleScope.launch {
                        handleDeviceTrustCertificateSelection(alias)
                    }
                }
            },
            arrayOf("RSA", "EC"),
            null,
            null,
            preferredAlias,
        )
    }

    private suspend fun handleDeviceTrustCertificateSelection(alias: String?) {
        if (alias.isNullOrBlank()) {
            Log.i(
                TAG,
                "Android KeyChain chooser returned no alias. No selectable identities were available in the current profile, or access was denied.",
            )
            showDeviceTrustMessageDialog(getString(R.string.device_trust_no_selectable_certificate))
            return
        }

        val inspection =
            withContext(Dispatchers.IO) {
                inspectDeviceTrustCertificate(requireContext(), alias)
            }

        if (inspection == null || !inspection.isUsable) {
            Log.i(
                TAG,
                "Selected Android KeyChain alias=$alias is not usable for device trust",
            )
            showDeviceTrustMessageDialog(getString(R.string.device_trust_invalid_selection))
            return
        }

        if (alias == viewModel.managedDeviceTrustCertificateAlias()) {
            viewModel.clearDeviceTrustCertificateAliasSelection()
        } else {
            viewModel.onDeviceTrustCertificateAliasSelected(alias)
        }
        refreshDeviceTrustCertificateState()
    }

    private fun applyDeviceTrustCertificateState(state: SettingsViewModel.DeviceTrustCertificateUiState) {
        binding.tvDeviceTrustCertificateStatus.text = state.statusMessage
        binding.btSelectDeviceTrustCertificate.text =
            if (state.alias == null) {
                getString(R.string.select_device_trust_certificate)
            } else {
                getString(R.string.select_different_device_trust_certificate)
            }
        binding.btShowDeviceTrustCertificateDetails.visibility =
            if (state.alias == null) View.GONE else View.VISIBLE
    }

    private fun yesNo(value: Boolean): String =
        if (value) {
            getString(R.string.device_trust_yes)
        } else {
            getString(R.string.device_trust_no)
        }

    private fun showDeviceTrustMessageDialog(message: String) {
        if (!isAdded) {
            return
        }

        AlertDialog
            .Builder(requireContext())
            .setTitle(R.string.device_trust_certificate_title)
            .setMessage(message)
            .setPositiveButton(R.string.error_dialog_button_text, null)
            .show()
    }

    private fun showDeviceTrustDetailsDialog() {
        val state = viewModel.deviceTrustCertificateStateFlow.value
        if (state.alias == null || !isAdded) {
            return
        }

        AlertDialog
            .Builder(requireContext())
            .setTitle(R.string.device_trust_certificate_details_title)
            .setMessage(deviceTrustDetailsMessage(state))
            .setPositiveButton(R.string.error_dialog_button_text, null)
            .show()
    }

    private fun deviceTrustDetailsMessage(state: SettingsViewModel.DeviceTrustCertificateUiState): String =
        buildString {
            appendLine(getString(R.string.device_trust_label_alias, state.alias ?: getString(R.string.device_trust_unknown_value)))
            appendLine(
                getString(
                    R.string.device_trust_label_subject_cn,
                    state.subjectCommonName ?: getString(R.string.device_trust_unknown_value),
                ),
            )
            appendLine(
                getString(
                    R.string.device_trust_label_issuer_cn,
                    state.issuerCommonName ?: getString(R.string.device_trust_unknown_value),
                ),
            )
            appendLine(
                getString(
                    R.string.device_trust_label_sha256,
                    state.sha256 ?: getString(R.string.device_trust_unknown_value),
                ),
            )
            appendLine(
                getString(
                    R.string.device_trust_label_client_auth,
                    yesNo(state.isClientAuthCertificate),
                ),
            )
            appendLine(
                getString(
                    R.string.device_trust_label_private_key,
                    yesNo(state.isPrivateKeyAccessible),
                ),
            )
            append(getString(R.string.device_trust_label_valid_now, yesNo(state.isCurrentlyValid)))
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

    companion object {
        private const val TAG = "DeviceTrust"
    }
}
