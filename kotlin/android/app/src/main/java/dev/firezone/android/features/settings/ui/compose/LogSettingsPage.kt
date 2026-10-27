// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui.compose

import android.text.format.Formatter
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import dev.firezone.android.R
import dev.firezone.android.core.data.model.Config
import dev.firezone.android.core.data.model.ManagedConfigStatus
import dev.firezone.android.ui.FirezoneIcons

@Composable
fun LogSettingsPage(
    config: Config,
    managedStatus: ManagedConfigStatus,
    logSizeBytes: Long,
    onLogFilterChange: (String) -> Unit,
    onClearLogs: () -> Unit,
    onExportLogs: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val hasLogs = logSizeBytes > 0

    Column(
        modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp, vertical = 8.dp),
    ) {
        SettingsGroup(title = stringResource(R.string.log_settings_title)) {
            TextPreferenceRow(
                title = stringResource(R.string.log_filter),
                value = config.logFilter,
                isManaged = managedStatus.isLogFilterManaged,
                onValueChange = onLogFilterChange,
                isValid = String::isNotBlank,
            )
            SettingsRow(
                title = stringResource(R.string.log_files),
                summary = Formatter.formatShortFileSize(context, logSizeBytes),
            ) {
                Row(Modifier.offset(x = ICON_BUTTON_INSET)) {
                    IconButton(onClick = onExportLogs, enabled = hasLogs) {
                        Icon(imageVector = FirezoneIcons.Share, contentDescription = stringResource(R.string.share_diagnostic_logs))
                    }
                    IconButton(onClick = onClearLogs, enabled = hasLogs) {
                        Icon(imageVector = FirezoneIcons.Delete, contentDescription = stringResource(R.string.clear_log_directory))
                    }
                }
            }
        }
    }
}
