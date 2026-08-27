// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.signin.ui

import android.content.Intent
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import androidx.appcompat.app.AlertDialog
import androidx.compose.runtime.getValue
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.ViewCompositionStrategy
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
import uniffi.x509claims.Actor
import uniffi.x509claims.Identity

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
                val identity by viewModel.certificateIdentityStateFlow.collectAsStateWithLifecycle()

                FirezoneTheme {
                    SignInScreen(
                        signInLabel = startSessionLabel(identity),
                        onSignIn = { startSession(identity) },
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
        viewModel.refreshCertificateIdentity()
    }

    /** What the sign-in control reads. A refused certificate still claims an account, so it offers to connect. */
    private fun startSessionLabel(identity: Identity): String =
        when (identity) {
            Identity.Absent -> getString(R.string.sign_in)
            is Identity.Resolved -> connectLabel(identity.actor)
            Identity.Refused -> getString(R.string.connect)
        }

    private fun connectLabel(actor: Actor): String =
        when (actor) {
            is Actor.Email -> getString(R.string.connect_as, actor.email)
            is Actor.Id -> getString(R.string.connect)
        }

    private fun startSession(identity: Identity) {
        when (identity) {
            Identity.Absent -> {
                startActivity(Intent(requireContext(), AuthActivity::class.java))
                requireActivity().finish()
            }

            is Identity.Resolved -> {
                // The certificate is the credential, so connect instead of opening a browser.
                TunnelService.start(requireContext())
                startActivity(
                    Intent(requireContext(), SessionActivity::class.java).apply {
                        flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
                    },
                )
                requireActivity().finish()
            }

            Identity.Refused -> {
                showInvalidCertificateDialog()
            }
        }
    }

    private fun showInvalidCertificateDialog() {
        AlertDialog
            .Builder(requireContext())
            .setTitle(R.string.error_dialog_title)
            .setMessage(R.string.error_dialog_message_invalid_certificate)
            .setPositiveButton(R.string.error_dialog_button_text, null)
            .show()
    }
}
