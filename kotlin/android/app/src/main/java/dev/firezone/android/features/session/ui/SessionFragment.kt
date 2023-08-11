package dev.firezone.android.features.session.ui

import android.os.Bundle
import android.view.View
import android.util.Log
import androidx.appcompat.app.AlertDialog
import androidx.fragment.app.Fragment
import androidx.fragment.app.viewModels
import androidx.navigation.fragment.findNavController
import dev.firezone.android.R
import dev.firezone.android.databinding.FragmentSessionBinding
import dagger.hilt.android.AndroidEntryPoint

@AndroidEntryPoint
internal class SessionFragment : Fragment(R.layout.fragment_session) {
    private lateinit var binding: FragmentSessionBinding
    private val viewModel: SessionViewModel by viewModels()

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        binding = FragmentSessionBinding.bind(view)

        setupButtonListeners()
        setupActionObservers()
        Log.d("SessionViewModel", "Starting session...")
        viewModel.startSession()
    }

    private fun setupActionObservers() {
        viewModel.actionLiveData.observe(viewLifecycleOwner) { action ->
            when (action) {
                SessionViewModel.ViewAction.NavigateToSignInFragment ->
                    findNavController().navigate(
                        SessionFragmentDirections.navigateToSignInFragment()
                    )
                SessionViewModel.ViewAction.ShowError -> showError()
            }
        }
    }

    private fun setupButtonListeners() {
        binding.btSignOut.setOnClickListener {
            viewModel.onDisconnect()
        }
    }

    private fun showError() {
        AlertDialog.Builder(requireContext())
            .setTitle(R.string.error_dialog_title)
            .setMessage(R.string.error_dialog_message)
            .setPositiveButton(
                R.string.error_dialog_button_text
            ) { dialog, _ ->
                dialog.dismiss()
            }
            .setIcon(R.drawable.ic_firezone_logo)
            .show()
    }
}
