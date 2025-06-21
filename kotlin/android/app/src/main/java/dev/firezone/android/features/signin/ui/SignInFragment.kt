/* Licensed under Apache 2.0 (C) 2024 Firezone, Inc. */
package dev.firezone.android.features.signin.ui

import android.content.Intent
import android.os.Bundle
import android.view.View
import androidx.fragment.app.Fragment
import androidx.fragment.app.viewModels
import androidx.navigation.fragment.findNavController
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.R
import dev.firezone.android.databinding.FragmentSignInBinding
import dev.firezone.android.features.auth.ui.AuthActivity
import dev.firezone.android.features.session.ui.SessionActivity

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
        setupActionObservers()
        setupButtonListener()
    }

    override fun onResume() {
        super.onResume()
        viewModel.checkTunnelState(requireContext(), false);
    }

    private fun setupActionObservers() {
        viewModel.actionLiveData.observe(viewLifecycleOwner) { action ->
            when (action) {
                SignInViewModel.ViewAction.NavigateToVpnPermission ->
                    findNavController().navigate(
                        R.id.vpnPermissionActivity,
                    )
                SignInViewModel.ViewAction.NavigateToSignIn ->
                    findNavController().navigate(
                        R.id.signInFragment,
                    )
                SignInViewModel.ViewAction.NavigateToSettings ->
                    findNavController().navigate(
                        R.id.settingsActivity,
                    )
                SignInViewModel.ViewAction.NavigateToSession ->
                    startActivity(
                        Intent(requireContext(), SessionActivity::class.java).apply {
                            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
                        },
                    )
            }
        }
    }

    private fun setupButtonListener() {
        with(binding) {
            btSignIn.setOnClickListener {
                startActivity(
                    Intent(
                        requireContext(),
                        AuthActivity::class.java,
                    ),
                )
                requireActivity().finish()
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
}
