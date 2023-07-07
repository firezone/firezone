package dev.firezone.android.features.onboarding.presentation

import android.os.Bundle
import android.view.View
import android.view.inputmethod.EditorInfo
import androidx.core.widget.doOnTextChanged
import androidx.fragment.app.Fragment
import androidx.fragment.app.viewModels
import androidx.navigation.fragment.findNavController
import dev.firezone.android.R
import dev.firezone.android.databinding.FragmentOnboardingBinding
import dagger.hilt.android.AndroidEntryPoint

@AndroidEntryPoint
internal class OnboardingFragment : Fragment(R.layout.fragment_onboarding) {

    private lateinit var binding: FragmentOnboardingBinding
    private val viewModel: OnboardingViewModel by viewModels()
    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        binding = FragmentOnboardingBinding.bind(view)

        setupInputListener()
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
                OnboardingViewAction.NavigateToSignInFragment ->
                    findNavController().navigate(
                        OnboardingFragmentDirections.navigateToSignInFragment()
                    )
                is OnboardingViewAction.FillPortalUrl -> {
                    binding.etInput.apply {
                        setText(action.value)
                        isCursorVisible = false
                    }
                }
            }
        }
    }

    private fun setupInputListener() {
        binding.etInput.apply {
            imeOptions = EditorInfo.IME_ACTION_DONE
            setOnClickListener { isCursorVisible = true }
            doOnTextChanged { input, _, _, _ ->
                viewModel.onValidateInput(input.toString())
            }
        }
    }

    private fun setupButtonListener() {
        binding.btLogin.setOnClickListener {
            viewModel.onSaveOnboardingCompleted()
        }
    }
}
