package dev.firezone.android.features.splash.presentation

import android.os.Bundle
import android.view.View
import androidx.activity.result.contract.ActivityResultContracts
import androidx.fragment.app.Fragment
import androidx.fragment.app.viewModels
import androidx.navigation.fragment.findNavController
import dev.firezone.android.R
import dev.firezone.android.databinding.FragmentSplashBinding
import dagger.hilt.android.AndroidEntryPoint

@AndroidEntryPoint
internal class SplashFragment : Fragment(R.layout.fragment_splash) {

    private lateinit var binding: FragmentSplashBinding
    private val viewModel: SplashViewModel by viewModels()
    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        binding = FragmentSplashBinding.bind(view)

        setupActionObservers()

        //TODO: Rewrite to accommodate better UX
        //requestPermissions()

        viewModel.onGetUserInfo()
    }

    private fun setupActionObservers() {
        viewModel.actionLiveData.observe(viewLifecycleOwner) { action ->
            when (action) {
                is SplashViewAction.NavigateToSignInFragment -> findNavController().navigate(
                    SplashFragmentDirections.navigateToSignInFragment()
                )
                SplashViewAction.NavigateToOnboardingFragment -> findNavController().navigate(
                    SplashFragmentDirections.navigateToOnboardingFragment()
                )
                SplashViewAction.NavigateToSessionFragment -> findNavController().navigate(
                    SplashFragmentDirections.navigateToSessionFragment()
                )
            }
        }
    }

    private fun requestPermissions() {
        val result = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {}
        val permissionIntent = android.net.VpnService.prepare(requireContext())
        if (permissionIntent != null) {
            result.launch(permissionIntent)
        }
    }
}
