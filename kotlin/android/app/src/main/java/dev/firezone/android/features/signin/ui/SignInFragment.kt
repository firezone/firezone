// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.signin.ui

import android.content.Intent
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import androidx.compose.runtime.getValue
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.ViewCompositionStrategy
import androidx.compose.ui.res.stringResource
import androidx.fragment.app.Fragment
import androidx.fragment.app.viewModels
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.fragment.findNavController
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.R
import dev.firezone.android.features.auth.ui.AuthActivity
import dev.firezone.android.features.session.ui.SessionActivity
import dev.firezone.android.features.session.ui.compose.FirezoneTheme
import dev.firezone.android.features.signin.ui.compose.SignInScreen
import dev.firezone.android.tunnel.TunnelService

@AndroidEntryPoint
internal class SignInFragment : Fragment() {
    private val viewModel: SignInViewModel by viewModels()

    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?,
    ): View =
        ComposeView(requireContext()).apply {
            setViewCompositionStrategy(ViewCompositionStrategy.DisposeOnViewTreeLifecycleDestroyed)
            setContent {
                val certificateUser by viewModel.certificateUserStateFlow.collectAsStateWithLifecycle()

                FirezoneTheme {
                    SignInScreen(
                        signInLabel =
                            certificateUser
                                ?.let { stringResource(R.string.connect_as, it.email) }
                                ?: stringResource(R.string.sign_in),
                        onSignIn = {
                            if (certificateUser == null) {
                                startActivity(Intent(requireContext(), AuthActivity::class.java))
                            } else {
                                // The certificate is the credential, so connect instead of opening a browser.
                                TunnelService.start(requireContext())
                                startActivity(
                                    Intent(requireContext(), SessionActivity::class.java).apply {
                                        flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
                                    },
                                )
                            }
                            requireActivity().finish()
                        },
                        onSettings = {
                            val bundle = Bundle().apply { putBoolean("isUserSignedIn", false) }
                            findNavController().navigate(R.id.settingsActivity, bundle)
                        },
                    )
                }
            }
        }

    override fun onResume() {
        super.onResume()

        // The administrator can grant the certificate while this screen is open.
        viewModel.refreshCertificateUser()
    }
}
