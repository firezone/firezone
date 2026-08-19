// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.settings.ui

import android.os.Bundle
import android.security.KeyChain
import android.view.View
import android.view.inputmethod.EditorInfo
import android.widget.Toast
import androidx.appcompat.widget.TooltipCompat
import androidx.core.widget.doOnTextChanged
import androidx.fragment.app.Fragment
import androidx.fragment.app.activityViewModels
import androidx.fragment.app.viewModels
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.R
import dev.firezone.android.core.data.model.ManagedConfigStatus
import dev.firezone.android.databinding.FragmentSettingsAdvancedBinding
import kotlinx.coroutines.launch

@AndroidEntryPoint
class AdvancedSettingsFragment : Fragment(R.layout.fragment_settings_advanced) {
    private var _binding: FragmentSettingsAdvancedBinding? = null

    val binding get() = _binding!!

    private val viewModel: SettingsViewModel by activityViewModels()
    private val x509ViewModel: X509SettingsViewModel by viewModels()

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

            x509Section.apply {
                btSelectX509Certificate.setOnClickListener { chooseCertificate() }
                btForgetX509Certificate.setOnClickListener { x509ViewModel.forgetSelection() }
                btRefreshX509.setOnClickListener { x509ViewModel.loadDetails() }
            }
        }
    }

    override fun onResume() {
        super.onResume()

        // The administrator can install or revoke the certificate while this screen is open.
        x509ViewModel.loadDetails()
    }

    private fun chooseCertificate() {
        val activity = requireActivity()

        // Android answers on a binder thread, so the ViewModel takes the alias directly and only
        // the toast has to hop onto the main thread.
        KeyChain.choosePrivateKeyAlias(
            activity,
            { alias ->
                if (alias == null) {
                    activity.runOnUiThread {
                        Toast
                            .makeText(activity, R.string.x509_no_certificate_selected, Toast.LENGTH_LONG)
                            .show()
                    }
                } else {
                    x509ViewModel.onAliasSelected(alias)
                }
            },
            arrayOf("RSA", "EC"),
            null,
            x509ViewModel.keyChainRequestUri(),
            x509ViewModel.uiStateFlow.value.alias,
        )
    }

    private fun renderX509(state: X509SettingsViewModel.UiState) {
        binding.x509Section.apply {
            tvX509Guidance.setText(
                if (state.isManaged) R.string.x509_managed_description else R.string.x509_user_description,
            )
            btSelectX509Certificate.visibility = if (state.isManaged) View.GONE else View.VISIBLE
            btForgetX509Certificate.visibility =
                if (!state.isManaged && state.alias != null) View.VISIBLE else View.GONE
            btRefreshX509.isEnabled = !state.isLoading
            progressX509.visibility = if (state.isLoading) View.VISIBLE else View.GONE

            tvX509Summary.text =
                if (state.alias == null) {
                    getString(R.string.x509_not_configured)
                } else {
                    getString(R.string.x509_alias_configured, state.alias)
                }

            tvX509Error.text =
                if (state.error == null) {
                    ""
                } else {
                    listOf(
                        getString(R.string.x509_error_title),
                        state.error,
                        getString(R.string.x509_contact_admin),
                    ).joinToString("\n\n")
                }
            tvX509Error.visibility = if (state.error == null) View.GONE else View.VISIBLE

            tvX509Details.text = state.details
            tvX509Details.visibility = if (state.details.isEmpty()) View.GONE else View.VISIBLE
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
                    x509ViewModel.uiStateFlow.collect { state -> renderX509(state) }
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
