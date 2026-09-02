// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui.compose

import android.text.format.Formatter
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import dev.firezone.android.R

@Composable
fun LogSettingsPage(
    logSizeBytes: Long,
    onClearLogs: () -> Unit,
    onExportLogs: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val hasLogs = logSizeBytes > 0

    Column(
        modifier.fillMaxSize().padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(
            text = stringResource(R.string.log_directory_size, Formatter.formatShortFileSize(context, logSizeBytes)),
            style = MaterialTheme.typography.titleMedium,
        )
        OutlinedButton(onClick = onClearLogs, enabled = hasLogs, modifier = Modifier.fillMaxWidth()) {
            Icon(painter = painterResource(R.drawable.rounded_delete_black_24dp), contentDescription = null)
            Text(text = stringResource(R.string.clear_log_directory), modifier = Modifier.padding(start = 8.dp))
        }
        OutlinedButton(onClick = onExportLogs, enabled = hasLogs, modifier = Modifier.fillMaxWidth()) {
            Icon(painter = painterResource(R.drawable.rounded_share_black_24dp), contentDescription = null)
            Text(text = stringResource(R.string.share_diagnostic_logs), modifier = Modifier.padding(start = 8.dp))
        }
    }
}
