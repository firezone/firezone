// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.signin.ui

import android.content.Intent
import android.os.Bundle
import android.view.View
import androidx.appcompat.app.AlertDialog
import androidx.fragment.app.Fragment
import androidx.fragment.app.viewModels
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import androidx.navigation.fragment.findNavController
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.R
import dev.firezone.android.databinding.FragmentSignInBinding
import dev.firezone.android.features.auth.ui.AuthActivity
import dev.firezone.android.features.session.ui.SessionActivity
import dev.firezone.android.tunnel.TunnelService
import kotlinx.coroutines.launch
import uniffi.x509claims.Actor
import uniffi.x509claims.Identity

@AndroidEntryPoint
internal class SignInFragment : Fragment(R.layout.fragment_sign_in) {
    private lateinit var binding: FragmentSignInBinding
    private val viewModel: SignInViewModel by viewModels()

    override fun onViewCreated(
        view: View,
        savedInstanceState: Bundle?,
    ) {
        super.onViewCreated(view, savedInstanceState)
        binding = FragmentSignInBinding.bind(view)

        setupCertificateIdentityObserver()
        setupButtonListener()
    }

    override fun onResume() {
        super.onResume()

        // The administrator can grant the certificate while this screen is open.
        viewModel.refreshCertificateIdentity()
    }

    private fun setupCertificateIdentityObserver() {
        viewLifecycleOwner.lifecycleScope.launch {
            viewLifecycleOwner.repeatOnLifecycle(Lifecycle.State.STARTED) {
                viewModel.certificateIdentityStateFlow.collect { identity ->
                    binding.btSignIn.text = startSessionLabel(identity)
                    binding.tvSessionStatus.text = getString(R.string.signed_out)
                }
            }
        }
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

    private fun setupButtonListener() {
        with(binding) {
            btSignIn.setOnClickListener {
                when (viewModel.certificateIdentityStateFlow.value) {
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
            btSettings.setOnClickListener {
                val bundle =
                    Bundle().apply {
                        putBoolean("isUserSignedIn", false)
                    }
                findNavController().navigate(
                    R.id.settingsActivity,
                    bundle,
                )
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
