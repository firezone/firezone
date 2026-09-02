// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.Toast
import androidx.compose.runtime.getValue
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.ViewCompositionStrategy
import androidx.fragment.app.Fragment
import androidx.fragment.app.viewModels
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.R
import dev.firezone.android.core.x509.KeyChain
import dev.firezone.android.features.session.ui.compose.FirezoneTheme
import dev.firezone.android.features.settings.ui.compose.DeviceTrustSettingsScreen
import javax.inject.Inject

@AndroidEntryPoint
class DeviceTrustSettingsFragment : Fragment() {
    private val viewModel: DeviceTrustSettingsViewModel by viewModels()

    @Inject
    lateinit var keyChain: KeyChain

    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?,
    ): View =
        ComposeView(requireContext()).apply {
            setViewCompositionStrategy(ViewCompositionStrategy.DisposeOnViewTreeLifecycleDestroyed)
            setContent {
                val state by viewModel.uiStateFlow.collectAsStateWithLifecycle()

                FirezoneTheme {
                    DeviceTrustSettingsScreen(
                        state = state,
                        onSelectCertificate = ::chooseCertificate,
                        onForgetCertificate = ::forgetCertificate,
                    )
                }
            }
        }

    override fun onResume() {
        super.onResume()

        // The administrator can install or revoke the certificate while this screen is open.
        viewModel.loadDetails()
    }

    private fun chooseCertificate() {
        val activity = requireActivity()

        // Android answers on a binder thread, so the ViewModel takes the alias directly and only
        // the toast has to hop onto the main thread.
        keyChain.choosePrivateKeyAlias(
            activity,
            viewModel.keyChainRequestUri(),
            viewModel.uiStateFlow.value.alias,
        ) { alias ->
            if (alias == null) {
                activity.runOnUiThread {
                    Toast
                        .makeText(activity, R.string.device_trust_no_certificate_selected, Toast.LENGTH_LONG)
                        .show()
                }
            } else {
                viewModel.onAliasSelected(alias)
            }
        }
    }

    private fun forgetCertificate() {
        viewModel.forgetSelection()

        // The activity fixes its page set at creation so the pager and navigation always agree.
        // Recreating it makes the now-unconfigured Device Trust page disappear too.
        requireActivity().recreate()
    }
}
