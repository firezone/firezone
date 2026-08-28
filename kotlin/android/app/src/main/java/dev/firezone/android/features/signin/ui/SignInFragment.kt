// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.signin.ui

import android.content.Intent
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.ViewCompositionStrategy
import androidx.fragment.app.Fragment
import androidx.navigation.fragment.findNavController
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.R
import dev.firezone.android.features.auth.ui.AuthActivity
import dev.firezone.android.features.session.ui.compose.FirezoneTheme
import dev.firezone.android.features.signin.ui.compose.SignInScreen

@AndroidEntryPoint
internal class SignInFragment : Fragment() {
    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?,
    ): View =
        ComposeView(requireContext()).apply {
            setViewCompositionStrategy(ViewCompositionStrategy.DisposeOnViewTreeLifecycleDestroyed)
            setContent {
                FirezoneTheme {
                    SignInScreen(
                        onSignIn = {
                            startActivity(Intent(requireContext(), AuthActivity::class.java))
                            requireActivity().finish()
                        },
                        onSettings = {
                            val bundle = Bundle().apply { putBoolean("isUserSignedIn", false) }
                            findNavController().navigate(R.id.settingsActivity, bundle)
                        },
                    )
                }
            }
        }
}
