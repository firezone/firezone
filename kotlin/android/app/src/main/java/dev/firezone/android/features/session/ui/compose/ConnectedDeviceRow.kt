// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.session.ui.compose

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import dev.firezone.android.tunnel.model.ConnectedDevice

@Composable
fun ConnectedDeviceRow(
    device: ConnectedDevice,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    // The row is a single line, so it needs less vertical padding than the two-line resource rows
    // to avoid looking sparse.
    Text(
        text = device.name,
        style = MaterialTheme.typography.bodyMedium,
        modifier = modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 12.dp),
    )
}

@Preview(showBackground = true)
@Composable
private fun ConnectedDeviceRowPreview() {
    FirezoneTheme {
        Column {
            ConnectedDeviceRow(
                ConnectedDevice(
                    "1",
                    "Device 1",
                    "100.96.0.12",
                    "fd00:2021:1111::1",
                    listOf("engineering"),
                ),
                onClick = {},
            )
            ConnectedDeviceRow(
                ConnectedDevice(
                    "2",
                    "Device 2",
                    "100.96.0.30",
                    "fd00:2021:1111::2",
                    listOf("engineering", "ops"),
                ),
                onClick = {},
            )
            ConnectedDeviceRow(
                ConnectedDevice(
                    "3",
                    "Device 3",
                    "100.96.0.41",
                    "fd00:2021:1111::3",
                    emptyList(),
                ),
                onClick = {},
            )
        }
    }
}
