// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.settings.ui

import android.content.Context
import android.content.Intent
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
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.data.model.ManagedConfigStatus
import dev.firezone.android.features.permission.ui.CertificatePermissionViewModel
import dev.firezone.android.features.settings.ui.compose.SettingsScreen
import dev.firezone.android.ui.theme.FirezoneTheme
import javax.inject.Inject

@AndroidEntryPoint
internal class SettingsActivity : AppCompatActivity() {
    private val viewModel: SettingsViewModel by viewModels()
    private val deviceTrustViewModel: DeviceTrustSettingsViewModel by viewModels()
    private val certificatePermissionViewModel: CertificatePermissionViewModel by viewModels()

    @Inject
    internal lateinit var repository: Repository

    @Inject
    internal lateinit var applicationRestrictions: Bundle

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val isUserSignedIn = intent.getBooleanExtra(EXTRA_IS_USER_SIGNED_IN, false)

        setContent {
            FirezoneTheme {
                val managedStatus by viewModel.managedStatusStateFlow.collectAsStateWithLifecycle()
                val uiState by viewModel.uiState.collectAsStateWithLifecycle()
                val deviceTrustState by deviceTrustViewModel.uiStateFlow.collectAsStateWithLifecycle()
                val action by viewModel.actionStateFlow.collectAsStateWithLifecycle()

                LaunchedEffect(action) {
                    action?.let {
                        viewModel.clearAction()
                        when (it) {
                            SettingsViewModel.ViewAction.NavigateBack -> finish()
                        }
                    }
                }

                SettingsScreen(
                    config = viewModel.config,
                    managedStatus = managedStatus ?: ManagedConfigStatus.NOTHING_MANAGED,
                    isSaveEnabled = uiState.isSaveButtonEnabled,
                    logSizeBytes = uiState.logSizeBytes,
                    deviceTrustState = deviceTrustState,
                    // The page exists where a certificate is required or one was found, and
                    // nowhere else.
                    showDeviceTrust =
                        repository.isX509CertificateRequired(applicationRestrictions) ||
                            deviceTrustState.alias != null,
                    warnBeforeSaving = isUserSignedIn,
                    onAuthUrlChange = viewModel::onValidateAuthUrl,
                    onApiUrlChange = viewModel::onValidateApiUrl,
                    onLogFilterChange = viewModel::onValidateLogFilter,
                    onAccountSlugChange = viewModel::onValidateAccountSlug,
                    onStartOnLoginChange = viewModel::onStartOnLoginChanged,
                    onConnectOnStartChange = viewModel::onConnectOnStartChanged,
                    onResetToDefaults = viewModel::resetSettingsToDefaults,
                    onClearLogs = { viewModel.deleteLogDirectory(applicationContext) },
                    onExportLogs = { viewModel.createLogZip(this@SettingsActivity) },
                    onLogsShown = { viewModel.onViewResume(applicationContext) },
                    onSelectCertificate = ::chooseCertificate,
                    onDeviceTrustShown = deviceTrustViewModel::loadDetails,
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
        certificatePermissionViewModel.chooseCertificate(this) { outcome ->
            runOnUiThread {
                when (outcome) {
                    CertificatePermissionViewModel.Outcome.Selected -> {
                        deviceTrustViewModel.loadDetails()
                    }

                    CertificatePermissionViewModel.Outcome.NothingSelected -> {
                        toast(getString(R.string.device_trust_no_certificate_selected))
                    }

                    is CertificatePermissionViewModel.Outcome.NotADeviceCertificate -> {
                        toast(getString(R.string.device_trust_not_device_certificate, outcome.alias))
                    }
                }
            }
        }
    }

    private fun toast(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_LONG).show()
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
