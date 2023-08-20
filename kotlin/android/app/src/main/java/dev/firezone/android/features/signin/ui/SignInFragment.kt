package dev.firezone.android.features.signin.ui

import android.util.Log
import android.os.Bundle
import android.view.View
import androidx.fragment.app.Fragment
import androidx.fragment.app.viewModels
import androidx.navigation.fragment.findNavController
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.R
import dev.firezone.android.databinding.FragmentSignInBinding
import dev.firezone.android.features.splash.ui.SplashFragmentDirections

@AndroidEntryPoint
internal class SignInFragment : Fragment(R.layout.fragment_sign_in) {
    private lateinit var binding: FragmentSignInBinding
    private val viewModel: SignInViewModel by viewModels()

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        binding = FragmentSignInBinding.bind(view)

        setupActionObservers()
        setupButtonListener()
        Log.d("SignInFragment", "Showing sign in...")
    }

    private fun setupActionObservers() {
        viewModel.actionLiveData.observe(viewLifecycleOwner) { action ->
            when (action) {
                SignInViewModel.SignInViewAction.NavigateToAuthActivity -> findNavController().navigate(
                    R.id.sessionFragment
                )
            }
        }
    }

    private fun setupButtonListener() {
        with(binding) {
            btSignIn.setOnClickListener {
                findNavController().navigate(
                    R.id.sessionFragment
                )
            }
            btSettings.setOnClickListener {
                findNavController().navigate(
                    SplashFragmentDirections.navigateToSettingsFragment()
                )
            }
        }
    }
}
