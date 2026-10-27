// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui.compose

import android.text.format.Formatter
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import dev.firezone.android.R
import dev.firezone.android.core.data.model.Config
import dev.firezone.android.core.data.model.ManagedConfigStatus
import dev.firezone.android.core.utils.ClipboardUtils
import dev.firezone.android.features.settings.ui.logFilterError
import dev.firezone.android.ui.FirezoneIcons

@Composable
fun LogSettingsPage(
    config: Config,
    managedStatus: ManagedConfigStatus,
    logSizeBytes: Long,
    onLogFilterChange: (String) -> Unit,
    onClearLogs: () -> Unit,
    onExportLogs: () -> Unit,
    versionName: String,
    buildSha: String,
    modifier: Modifier = Modifier,
    validateLogFilter: (String) -> String? = ::logFilterError,
) {
    val context = LocalContext.current
    val uriHandler = LocalUriHandler.current
    val hasLogs = logSizeBytes > 0
    val version = "$versionName (${buildSha.take(8)})"
    var showClearConfirmation by rememberSaveable { mutableStateOf(false) }

    Column(
        modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        SettingsGroup(title = stringResource(R.string.log_settings_title)) {
            TextPreferenceRow(
                title = stringResource(R.string.log_filter),
                value = config.logFilter,
                isManaged = managedStatus.isLogFilterManaged,
                onValueChange = onLogFilterChange,
                isValid = String::isNotBlank,
                errorMessage = { filter -> validateLogFilter(filter)?.let { stringResource(R.string.log_filter_invalid, it) } },
            )
            SettingsRow(
                title = stringResource(R.string.log_files),
                summary = Formatter.formatShortFileSize(context, logSizeBytes),
            ) {
                Row(Modifier.offset(x = ICON_BUTTON_INSET)) {
                    IconButton(onClick = onExportLogs, enabled = hasLogs) {
                        Icon(imageVector = FirezoneIcons.Share, contentDescription = stringResource(R.string.share_diagnostic_logs))
                    }
                    IconButton(onClick = { showClearConfirmation = true }, enabled = hasLogs) {
                        Icon(imageVector = FirezoneIcons.Delete, contentDescription = stringResource(R.string.clear_log_directory))
                    }
                }
            }
        }
        SettingsGroup(title = stringResource(R.string.settings_section_about)) {
            SettingsRow(
                title = stringResource(R.string.version),
                summary = versionName,
            ) {
                if (buildSha != "unknown") {
                    Text(
                        text = "${buildSha.take(8)} (GitHub)",
                        color = MaterialTheme.colorScheme.primary,
                        textDecoration = TextDecoration.Underline,
                        modifier =
                            Modifier.combinedClickable(
                                onClick = { uriHandler.openUri("https://github.com/firezone/firezone/commit/$buildSha") },
                                onLongClick = { ClipboardUtils.copyToClipboard(context, "Version", version) },
                            ),
                    )
                }
            }
        }
    }

    if (showClearConfirmation) {
        AlertDialog(
            onDismissRequest = { showClearConfirmation = false },
            title = { Text(stringResource(R.string.clear_logs_confirm_title)) },
            text = { Text(stringResource(R.string.clear_logs_confirm_message)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        showClearConfirmation = false
                        onClearLogs()
                    },
                ) {
                    Text(stringResource(R.string.clear_logs_confirm))
                }
            },
            dismissButton = {
                TextButton(onClick = { showClearConfirmation = false }) {
                    Text(stringResource(android.R.string.cancel))
                }
            },
        )
    }
}
