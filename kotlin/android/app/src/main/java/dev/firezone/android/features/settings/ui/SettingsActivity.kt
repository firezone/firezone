// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.settings.ui

import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.appcompat.app.AppCompatActivity
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.features.settings.ui.compose.SettingsScreen
import dev.firezone.android.ui.theme.FirezoneTheme

@AndroidEntryPoint
internal class SettingsActivity : AppCompatActivity() {
    private val viewModel: SettingsViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val isUserSignedIn = intent.getBooleanExtra("isUserSignedIn", false)

        setContent {
            FirezoneTheme {
                val config by viewModel.configStateFlow.collectAsStateWithLifecycle()
                val managedStatus by viewModel.managedStatusStateFlow.collectAsStateWithLifecycle()
                val uiState by viewModel.uiState.collectAsStateWithLifecycle()
                val action by viewModel.actionStateFlow.collectAsStateWithLifecycle()

                LaunchedEffect(action) {
                    action?.let {
                        viewModel.clearAction()
                        when (it) {
                            is SettingsViewModel.ViewAction.NavigateBack -> finish()
                        }
                    }
                }

                SettingsScreen(
                    config = config,
                    managedStatus = managedStatus,
                    isSaveEnabled = uiState.isSaveButtonEnabled,
                    logSizeBytes = uiState.logSizeBytes,
                    warnBeforeSaving = isUserSignedIn,
                    onConfigChange = viewModel::onConfigChanged,
                    onResetToDefaults = viewModel::resetSettingsToDefaults,
                    onClearLogs = { viewModel.deleteLogDirectory(this@SettingsActivity) },
                    onExportLogs = { viewModel.createLogZip(this@SettingsActivity) },
                    onLogsShown = { viewModel.onViewResume(this@SettingsActivity) },
                    onSave = viewModel::onSaveSettingsCompleted,
                    onCancel = viewModel::onCancel,
                )
            }
        }

        viewModel.populateFieldsFromConfig()
        viewModel.deleteLogZip(this@SettingsActivity)
    }

    override fun onResume() {
        super.onResume()
        viewModel.onViewResume(this@SettingsActivity)
    }

    override fun onStop() {
        super.onStop()
        if (isFinishing) {
            viewModel.deleteLogZip(this@SettingsActivity)
        }
    }
}
