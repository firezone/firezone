package dev.firezone.android.features.signin.presentation

import android.content.Intent
import android.os.Bundle
import android.view.View
import androidx.fragment.app.Fragment
import androidx.fragment.app.viewModels
import androidx.navigation.fragment.findNavController
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.R
import dev.firezone.android.databinding.FragmentSignInBinding
import dev.firezone.android.features.auth.presentation.AuthActivity
import dev.firezone.android.features.splash.presentation.SplashFragmentDirections


@AndroidEntryPoint
internal class SignInFragment : Fragment(R.layout.fragment_sign_in) {
    private lateinit var binding: FragmentSignInBinding
    private val viewModel: SignInViewModel by viewModels()

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        binding = FragmentSignInBinding.bind(view)

        setupActionObservers()
        setupButtonListener()
    }

    private fun setupActionObservers() {
        viewModel.actionLiveData.observe(viewLifecycleOwner) { action ->
            when (action) {
                SignInViewAction.NavigateToAuthActivity -> startActivity(
                    Intent(
                        requireContext(),
                        AuthActivity::class.java
                    )
                )
            }
        }
    }

    private fun setupButtonListener() {
        with(binding) {
            btSignIn.setOnClickListener {
                viewModel.onSaveAuthToken()
            }
            btSettings.setOnClickListener {
                findNavController().navigate(
                    SplashFragmentDirections.navigateToOnboardingFragment()
                )
            }
        }
    }
}
