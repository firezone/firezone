// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.session.ui.compose

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import dev.firezone.android.tunnel.model.ConnectedDevice

@Composable
fun ConnectedDeviceRow(
    device: ConnectedDevice,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier.fillMaxWidth().clickable(onClick = onClick).padding(16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        LiveDot()
        Spacer(Modifier.width(12.dp))
        Column {
            Text(
                text = device.tunneledIpv4,
                style = MaterialTheme.typography.bodyLarge,
                fontFamily = FontFamily.Monospace,
            )
            if (device.pools.isNotEmpty()) {
                Text(
                    text = device.pools.joinToString(", "),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Preview(showBackground = true)
@Composable
private fun ConnectedDeviceRowPreview() {
    FirezoneTheme {
        Column {
            ConnectedDeviceRow(ConnectedDevice("1", "100.64.0.12", listOf("engineering")), onClick = {})
            ConnectedDeviceRow(ConnectedDevice("2", "100.64.0.30", listOf("engineering", "ops")), onClick = {})
            ConnectedDeviceRow(ConnectedDevice("3", "100.64.0.41", emptyList()), onClick = {})
        }
    }
}
