// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.splash.ui

import android.content.Intent
import android.os.Bundle
import android.view.View
import androidx.fragment.app.Fragment
import androidx.fragment.app.viewModels
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import androidx.navigation.fragment.findNavController
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.R
import dev.firezone.android.databinding.FragmentSplashBinding
import dev.firezone.android.features.session.ui.SessionActivity
import kotlinx.coroutines.launch

@AndroidEntryPoint
internal class SplashFragment : Fragment(R.layout.fragment_splash) {
    private lateinit var binding: FragmentSplashBinding
    private val viewModel: SplashViewModel by viewModels()
    private var isInitialLaunch: Boolean = true

    override fun onViewCreated(
        view: View,
        savedInstanceState: Bundle?,
    ) {
        super.onViewCreated(view, savedInstanceState)
        binding = FragmentSplashBinding.bind(view)

        setupActionObservers()

        savedInstanceState?.let {
            isInitialLaunch = it.getBoolean("isInitialLaunch", true)
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)

        // Save the initial launch state to handle edge cases where the fragment is recreated
        outState.putBoolean("isInitialLaunch", isInitialLaunch)
    }

    override fun onResume() {
        super.onResume()
        viewModel.checkTunnelState(requireContext(), isInitialLaunch)

        isInitialLaunch = false
    }

    private fun setupActionObservers() {
        viewLifecycleOwner.lifecycleScope.launch {
            viewLifecycleOwner.repeatOnLifecycle(Lifecycle.State.STARTED) {
                viewModel.actionStateFlow.collect { action ->
                    action?.let {
                        viewModel.clearAction()
                        when (it) {
                            SplashViewModel.ViewAction.NavigateToVpnPermission ->
                                findNavController().navigate(
                                    R.id.vpnPermissionActivity,
                                )
                            SplashViewModel.ViewAction.NavigateToNotificationPermission ->
                                findNavController().navigate(
                                    R.id.notificationPermissionActivity,
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
        }
    }
}
