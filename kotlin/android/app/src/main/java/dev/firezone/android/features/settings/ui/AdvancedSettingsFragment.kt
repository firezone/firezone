package dev.firezone.android.features.settings.ui

import android.os.Bundle
import android.view.View
import android.view.inputmethod.EditorInfo
import androidx.core.widget.doOnTextChanged
import androidx.fragment.app.Fragment
import androidx.fragment.app.activityViewModels
import androidx.fragment.app.viewModels
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import dev.firezone.android.R
import dev.firezone.android.databinding.FragmentSettingsAdvancedBinding
import kotlinx.coroutines.launch

class AdvancedSettingsFragment : Fragment(R.layout.fragment_settings_advanced) {

    private var _binding: FragmentSettingsAdvancedBinding? = null
    private val binding get() = _binding!!
    private val viewModel: SettingsViewModel by activityViewModels()


    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        _binding = FragmentSettingsAdvancedBinding.bind(view)

        setupViews()
        setupActionObservers()
    }

    private fun setupViews() {
        binding.apply {
            etAuthBaseUrlInput.apply {
                imeOptions = EditorInfo.IME_ACTION_DONE
                setOnClickListener { isCursorVisible = true }
                doOnTextChanged { text, _, _, _ ->
                    viewModel.onValidateAuthBaseUrl(text.toString())
                }
            }

            etApiUrlInput.apply {
                imeOptions = EditorInfo.IME_ACTION_DONE
                setOnClickListener { isCursorVisible = true }
                doOnTextChanged { text, _, _, _ ->
                    viewModel.onValidateApiUrl(text.toString())
                }
            }

            etLogFilterInput.apply {
                imeOptions = EditorInfo.IME_ACTION_DONE
                setOnClickListener { isCursorVisible = true }
                doOnTextChanged { text, _, _, _ ->
                    viewModel.onValidateLogFilter(text.toString())
                }
            }
        }
    }

    private fun setupActionObservers() {
        viewModel.actionLiveData.observe(viewLifecycleOwner) { action ->
            when (action) {
                is SettingsViewModel.ViewAction.NavigateBack ->
                    requireActivity().finish()

                is SettingsViewModel.ViewAction.FillSettings -> {
                    binding.etAuthBaseUrlInput.apply {
                        setText(action.authBaseUrl)
                    }
                    binding.etApiUrlInput.apply {
                        setText(action.apiUrl)
                    }
                    binding.etLogFilterInput.apply {
                        setText(action.logFilter)
                    }
                }
            }
        }
    }

    override fun onDestroyView() {
        super.onDestroyView()
        _binding = null
    }
}
