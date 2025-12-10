// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.signin.ui

import android.content.Intent
import android.os.Bundle
import android.view.View
import androidx.fragment.app.Fragment
import androidx.navigation.fragment.findNavController
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.R
import dev.firezone.android.databinding.FragmentSignInBinding
import dev.firezone.android.features.auth.ui.AuthActivity

@AndroidEntryPoint
internal class SignInFragment : Fragment(R.layout.fragment_sign_in) {
    private lateinit var binding: FragmentSignInBinding

    override fun onViewCreated(
        view: View,
        savedInstanceState: Bundle?,
    ) {
        super.onViewCreated(view, savedInstanceState)
        binding = FragmentSignInBinding.bind(view)

        setupButtonListener()
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
