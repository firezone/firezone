// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.settings.ui

import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.widget.Toast
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.appcompat.app.AppCompatActivity
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.R
import dev.firezone.android.core.x509.KeyChain
import dev.firezone.android.features.settings.ui.compose.SettingsScreen
import dev.firezone.android.ui.theme.FirezoneTheme
import javax.inject.Inject

@AndroidEntryPoint
internal class SettingsActivity : AppCompatActivity() {
    private val viewModel: SettingsViewModel by viewModels()
    private val deviceTrustViewModel: DeviceTrustSettingsViewModel by viewModels()

    @Inject
    internal lateinit var keyChain: KeyChain

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val isUserSignedIn = intent.getBooleanExtra(EXTRA_IS_USER_SIGNED_IN, false)

        setContent {
            FirezoneTheme {
                val uiState by viewModel.uiState.collectAsStateWithLifecycle()
                val deviceTrustState by deviceTrustViewModel.uiStateFlow.collectAsStateWithLifecycle()
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
                    deviceTrustState = deviceTrustState,
                    // Device Trust has nothing to say until a certificate is configured, whether
                    // by an administrator or by the user.
                    hasConfiguredCertificateAlias = deviceTrustState.alias != null,
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
                    onSelectCertificate = ::chooseCertificate,
                    onForgetCertificate = deviceTrustViewModel::forgetSelection,
                    onDeviceTrustShown = deviceTrustViewModel::loadDetails,
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
        // The administrator can install or revoke the certificate while this screen is open.
        deviceTrustViewModel.loadDetails()
    }

    override fun onStop() {
        super.onStop()
        if (isFinishing) {
            viewModel.deleteLogZip(this@SettingsActivity)
        }
    }

    private fun chooseCertificate() {
        // Android answers on a binder thread, so the ViewModel takes the alias directly and only
        // the toast has to hop onto the main thread.
        keyChain.choosePrivateKeyAlias(
            this,
            deviceTrustViewModel.keyChainRequestUri(),
            deviceTrustViewModel.uiStateFlow.value.alias,
        ) { alias ->
            if (alias == null) {
                runOnUiThread {
                    Toast
                        .makeText(this, R.string.device_trust_no_certificate_selected, Toast.LENGTH_LONG)
                        .show()
                }
            } else {
                deviceTrustViewModel.onAliasSelected(alias)
            }
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
