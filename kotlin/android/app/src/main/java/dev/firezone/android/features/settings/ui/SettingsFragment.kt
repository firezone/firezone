/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.features.settings.ui

import android.os.Bundle
import android.view.View
import android.view.inputmethod.EditorInfo
import androidx.core.widget.doOnTextChanged
import androidx.fragment.app.Fragment
import androidx.fragment.app.viewModels
import androidx.navigation.fragment.findNavController
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.R
import dev.firezone.android.databinding.FragmentSettingsBinding

@AndroidEntryPoint
internal class SettingsFragment : Fragment(R.layout.fragment_settings) {

    private lateinit var binding: FragmentSettingsBinding
    private val viewModel: SettingsViewModel by viewModels()
    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        binding = FragmentSettingsBinding.bind(view)

        setupViews()
        setupStateObservers()
        setupActionObservers()
        setupButtonListener()

        viewModel.getAccountId()
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
                is SettingsViewModel.ViewAction.NavigateToSignInFragment -> findNavController().navigate(
                    R.id.signInFragment,
                )
                is SettingsViewModel.ViewAction.FillAccountId -> {
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
            prefixText = SettingsViewModel.AUTH_URL
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
            viewModel.onSaveSettingsCompleted()
        }
    }

    private fun setupButtonListener() {
    }
}
