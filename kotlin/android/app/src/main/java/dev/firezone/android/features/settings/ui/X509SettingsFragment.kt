// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui

import android.os.Bundle
import android.security.KeyChain
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
import dev.firezone.android.features.session.ui.compose.FirezoneTheme
import dev.firezone.android.features.settings.ui.compose.X509SettingsScreen

@AndroidEntryPoint
class X509SettingsFragment : Fragment() {
    private val viewModel: X509SettingsViewModel by viewModels()

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
                    X509SettingsScreen(
                        state = state,
                        onSelectCertificate = ::chooseCertificate,
                        onForgetCertificate = viewModel::forgetSelection,
                        onRefresh = viewModel::loadDetails,
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
                    viewModel.onAliasSelected(alias)
                }
            },
            arrayOf("RSA", "EC"),
            null,
            viewModel.keyChainRequestUri(),
            viewModel.uiStateFlow.value.alias,
        )
    }
}
