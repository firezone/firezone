package dev.firezone.android.features.signin.ui

import android.content.Intent
import android.util.Log
import android.os.Bundle
import android.view.View
import androidx.fragment.app.Fragment
import androidx.fragment.app.viewModels
import androidx.navigation.fragment.findNavController
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.R
import dev.firezone.android.databinding.FragmentSignInBinding
import dev.firezone.android.features.auth.ui.AuthActivity
import dev.firezone.android.features.splash.ui.SplashFragmentDirections

@AndroidEntryPoint
internal class SignInFragment : Fragment(R.layout.fragment_sign_in) {
    private lateinit var binding: FragmentSignInBinding
    private val viewModel: SignInViewModel by viewModels()

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        binding = FragmentSignInBinding.bind(view)

        Log.d("SignInFragment", "Showing sign in...")
        setupButtonListener()
    }

    private fun setupButtonListener() {
        with(binding) {
            btSignIn.setOnClickListener {
                startActivity(
                    Intent(
                        requireContext(),
                        AuthActivity::class.java
                    )
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
