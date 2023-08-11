package dev.firezone.android.features.onboarding.ui

import android.content.Intent
import android.os.Bundle
import android.view.View
import android.view.inputmethod.EditorInfo
import androidx.core.widget.doOnTextChanged
import androidx.fragment.app.Fragment
import androidx.fragment.app.viewModels
import dev.firezone.android.R
import dev.firezone.android.databinding.FragmentOnboardingBinding
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.BuildConfig
import dev.firezone.android.features.auth.ui.AuthActivity

@AndroidEntryPoint
internal class OnboardingFragment : Fragment(R.layout.fragment_onboarding) {

    private lateinit var binding: FragmentOnboardingBinding
    private val viewModel: OnboardingViewModel by viewModels()
    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        binding = FragmentOnboardingBinding.bind(view)

        setupViews()
        setupStateObservers()
        setupActionObservers()
        setupButtonListener()

        viewModel.getPortalUrl()
    }

    private fun setupStateObservers() {
        viewModel.stateLiveData.observe(viewLifecycleOwner) { state ->
            with(binding) {
                btLogin.isEnabled = state.isButtonEnabled
            }
        }
    }

    private fun setupActionObservers() {
        viewModel.actionLiveData.observe(viewLifecycleOwner) { action ->
            when (action) {
                OnboardingViewModel.ViewAction.NavigateToSignInFragment -> startActivity(
                    Intent(
                        requireContext(),
                        AuthActivity::class.java
                    )
                )
                is OnboardingViewModel.ViewAction.FillPortalUrl -> {
                    binding.etInput.apply {
                        setText(action.value)
                        isCursorVisible = false
                    }
                }
            }
        }
    }

    private fun setupViews() {
        binding.ilUrlInput.apply {
            prefixText = "${BuildConfig.AUTH_SCHEME}://${BuildConfig.AUTH_HOST}:${BuildConfig.AUTH_PORT}/"
        }

        binding.etInput.apply {
            imeOptions = EditorInfo.IME_ACTION_DONE
            setOnClickListener { isCursorVisible = true }
            doOnTextChanged { input, _, _, _ ->
                viewModel.onValidateInput(input.toString())
            }
            requestFocus()
        }

        binding.btLogin.setOnClickListener {
            viewModel.onSaveOnboardingCompleted()
        }
    }

    private fun setupButtonListener() {

    }
}
