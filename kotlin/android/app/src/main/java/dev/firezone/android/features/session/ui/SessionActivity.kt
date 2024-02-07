/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.features.session.ui

import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.viewModels
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import androidx.recyclerview.widget.DividerItemDecoration
import androidx.recyclerview.widget.LinearLayoutManager
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.R
import dev.firezone.android.core.presentation.MainActivity
import dev.firezone.android.core.utils.ClipboardUtils
import dev.firezone.android.databinding.ActivitySessionBinding
import dev.firezone.android.features.settings.ui.SettingsActivity
import kotlinx.coroutines.launch

@AndroidEntryPoint
internal class SessionActivity : AppCompatActivity() {
    private lateinit var binding: ActivitySessionBinding
    private val viewModel: SessionViewModel by viewModels()

    private val resourcesAdapter: ResourcesAdapter =
        ResourcesAdapter { resource ->
            ClipboardUtils.copyToClipboard(this@SessionActivity, resource.name, resource.address)
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivitySessionBinding.inflate(layoutInflater)
        setContentView(binding.root)

        setupViews()
        setupObservers()
        viewModel.signIn(this@SessionActivity)
    }

    private fun setupViews() {
        binding.btSignOut.setOnClickListener {
            viewModel.signOut(this@SessionActivity)
        }

        binding.btSettings.setOnClickListener {
            startActivity(Intent(this@SessionActivity, SettingsActivity::class.java))
        }

        val layoutManager = LinearLayoutManager(this@SessionActivity)
        val dividerItemDecoration =
            DividerItemDecoration(
                this@SessionActivity,
                layoutManager.orientation,
            )
        binding.rvResourcesList.addItemDecoration(dividerItemDecoration)
        binding.rvResourcesList.adapter = resourcesAdapter
        binding.rvResourcesList.layoutManager = layoutManager
    }

    private fun setupObservers() {
        viewModel.actionLiveData.observe(this@SessionActivity) { action ->
            when (action) {
                SessionViewModel.ViewAction.NavigateToSignIn -> {
                    startActivity(
                        Intent(this, MainActivity::class.java),
                    )
                    finish()
                }
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
        AlertDialog.Builder(this@SessionActivity)
            .setTitle(R.string.error_dialog_title)
            .setMessage(R.string.error_dialog_message)
            .setPositiveButton(
                R.string.error_dialog_button_text,
            ) { dialog, _ ->
                dialog.dismiss()
            }
            .setIcon(R.drawable.ic_firezone_logo)
            .show()
    }
}
