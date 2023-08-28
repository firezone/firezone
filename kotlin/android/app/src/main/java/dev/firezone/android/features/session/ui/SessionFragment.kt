package dev.firezone.android.features.session.ui

import android.os.Bundle
import android.util.Log
import android.view.View
import androidx.appcompat.app.AlertDialog
import androidx.fragment.app.Fragment
import androidx.fragment.app.viewModels
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import androidx.navigation.fragment.findNavController
import androidx.recyclerview.widget.DividerItemDecoration
import androidx.recyclerview.widget.LinearLayoutManager
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.R
import dev.firezone.android.databinding.FragmentSessionBinding
import kotlinx.coroutines.launch

@AndroidEntryPoint
internal class SessionFragment : Fragment(R.layout.fragment_session) {
    private lateinit var binding: FragmentSessionBinding
    private val viewModel: SessionViewModel by viewModels()

    private val resourcesAdapter: ResourcesAdapter = ResourcesAdapter()

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        binding = FragmentSessionBinding.bind(view)

        setupViews()
        setupObservers()
        Log.d("SessionFragment", "Starting session...")
        viewModel.startSession()
    }

    private fun setupViews() {
        binding.btSignOut.setOnClickListener {
            viewModel.onDisconnect()
        }

        val layoutManager = LinearLayoutManager(requireContext())
        val dividerItemDecoration = DividerItemDecoration(
            requireContext(),
            layoutManager.orientation
        )
        binding.resourcesList.addItemDecoration(dividerItemDecoration)
        binding.resourcesList.adapter = resourcesAdapter
        binding.resourcesList.layoutManager = layoutManager
    }

    private fun setupObservers() {
        viewModel.actionLiveData.observe(viewLifecycleOwner) { action ->
            when (action) {
                SessionViewModel.ViewAction.NavigateToSignInFragment ->
                    findNavController().navigate(
                        SessionFragmentDirections.navigateToSignInFragment()
                    )
                SessionViewModel.ViewAction.ShowError -> showError()
            }
        }

        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                viewModel.uiState.collect { uiState ->
                    uiState.resources?.let {
                        resourcesAdapter.updateResources(it)
                    }
                }
            }
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
