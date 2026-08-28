// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.settings.ui

import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.net.Uri
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

        val isUserSignedIn = intent.getBooleanExtra(EXTRA_IS_USER_SIGNED_IN, false)

        setContent {
            FirezoneTheme {
                val uiState by viewModel.uiState.collectAsStateWithLifecycle()
                val action by viewModel.actionStateFlow.collectAsStateWithLifecycle()

                LaunchedEffect(action) {
                    action?.let {
                        viewModel.clearAction()
                        when (it) {
                            is SettingsViewModel.ViewAction.NavigateBack -> finish()
                            is SettingsViewModel.ViewAction.ShareLogs -> shareLogs(it.uri)
                        }
                    }
                }

                SettingsScreen(
                    config = uiState.config,
                    managedStatus = uiState.managedStatus,
                    isSaveEnabled = uiState.isSaveButtonEnabled,
                    logSizeBytes = uiState.logSizeBytes,
                    warnBeforeSaving = isUserSignedIn,
                    onAuthUrlChange = viewModel::onAuthUrlChanged,
                    onApiUrlChange = viewModel::onApiUrlChanged,
                    onLogFilterChange = viewModel::onLogFilterChanged,
                    onAccountSlugChange = viewModel::onAccountSlugChanged,
                    onStartOnLoginChange = viewModel::onStartOnLoginChanged,
                    onConnectOnStartChange = viewModel::onConnectOnStartChanged,
                    onResetToDefaults = viewModel::resetSettingsToDefaults,
                    onClearLogs = { viewModel.deleteLogDirectory(applicationContext) },
                    onExportLogs = { viewModel.createLogZip(applicationContext) },
                    onLogsShown = { viewModel.onViewResume(applicationContext) },
                    onSave = viewModel::onSaveSettingsCompleted,
                    onCancel = viewModel::onCancel,
                )
            }
        }

        viewModel.deleteLogZip(this@SettingsActivity)
    }

    override fun onResume() {
        super.onResume()
        viewModel.populateFieldsFromConfig()
        viewModel.onViewResume(applicationContext)
    }

    override fun onStop() {
        super.onStop()
        if (isFinishing) {
            viewModel.deleteLogZip(this@SettingsActivity)
        }
    }

    private fun shareLogs(uri: Uri) {
        val sendIntent =
            Intent(Intent.ACTION_SEND).apply {
                type = "application/zip"
                putExtra(Intent.EXTRA_SUBJECT, "Sharing diagnostic logs")
                putExtra(Intent.EXTRA_STREAM, uri)
                clipData = ClipData.newRawUri("Diagnostic logs", uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
        startActivity(Intent.createChooser(sendIntent, null))
    }

    companion object {
        private const val EXTRA_IS_USER_SIGNED_IN = "isUserSignedIn"

        fun createIntent(
            context: Context,
            isUserSignedIn: Boolean,
        ): Intent =
            Intent(context, SettingsActivity::class.java)
                .putExtra(EXTRA_IS_USER_SIGNED_IN, isUserSignedIn)
    }
}
