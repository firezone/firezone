/* Licensed under Apache 2.0 (C) 2024 Firezone, Inc. */
package dev.firezone.android.features.splash.ui

import android.content.Intent
import android.os.Bundle
import android.view.View
import androidx.fragment.app.Fragment
import androidx.fragment.app.viewModels
import androidx.navigation.fragment.findNavController
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.R
import dev.firezone.android.databinding.FragmentSplashBinding
import dev.firezone.android.features.session.ui.SessionActivity

@AndroidEntryPoint
internal class SplashFragment : Fragment(R.layout.fragment_splash) {
    private lateinit var binding: FragmentSplashBinding
    private val viewModel: SplashViewModel by viewModels()

    override fun onViewCreated(
        view: View,
        savedInstanceState: Bundle?,
    ) {
        super.onViewCreated(view, savedInstanceState)
        binding = FragmentSplashBinding.bind(view)

        setupActionObservers()
    }

    override fun onResume() {
        super.onResume()
        viewModel.checkTunnelState(requireContext())
    }

    private fun setupActionObservers() {
        viewModel.actionLiveData.observe(viewLifecycleOwner) { action ->
            when (action) {
                SplashViewModel.ViewAction.NavigateToVpnPermission ->
                    findNavController().navigate(
                        R.id.vpnPermissionActivity,
                    )
                SplashViewModel.ViewAction.NavigateToSignIn ->
                    findNavController().navigate(
                        R.id.signInFragment,
                    )
                SplashViewModel.ViewAction.NavigateToSettings ->
                    findNavController().navigate(
                        R.id.settingsActivity,
                    )
                SplashViewModel.ViewAction.NavigateToSession ->
                    startActivity(
                        Intent(requireContext(), SessionActivity::class.java).apply {
                            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
                        },
                    )
            }
        }
    }
}
