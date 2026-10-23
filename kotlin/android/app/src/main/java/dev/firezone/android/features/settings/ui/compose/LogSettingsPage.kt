// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui.compose

import android.text.format.Formatter
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
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
            .padding(start = 16.dp, top = 4.dp, end = 16.dp, bottom = 8.dp),
    ) {
        SettingsSection(stringResource(R.string.log_settings_title)) {
            ManagedTextField(
                label = stringResource(R.string.log_filter),
                value = config.logFilter,
                isManaged = managedStatus.isLogFilterManaged,
                onValueChange = onLogFilterChange,
            )
            Text(
                text = stringResource(R.string.log_directory_size, Formatter.formatShortFileSize(context, logSizeBytes)),
                style = MaterialTheme.typography.bodyLarge,
                modifier = Modifier.padding(vertical = 8.dp),
            )
            OutlinedButton(onClick = onClearLogs, enabled = hasLogs, modifier = Modifier.fillMaxWidth()) {
                Icon(imageVector = FirezoneIcons.Delete, contentDescription = null)
                Text(text = stringResource(R.string.clear_log_directory), modifier = Modifier.padding(start = 8.dp))
            }
            OutlinedButton(onClick = onExportLogs, enabled = hasLogs, modifier = Modifier.fillMaxWidth()) {
                Icon(imageVector = FirezoneIcons.Share, contentDescription = null)
                Text(text = stringResource(R.string.share_diagnostic_logs), modifier = Modifier.padding(start = 8.dp))
            }
        }
    }
}
