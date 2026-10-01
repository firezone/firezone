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
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import dev.firezone.android.tunnel.model.ConnectedDevice
import dev.firezone.android.ui.theme.FirezoneTheme

@Composable
fun ConnectedDeviceRow(
    device: ConnectedDevice,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    // The row is a single line, so it needs less vertical padding than the two-line resource rows
    // to avoid looking sparse.
    Text(
        text = deviceLabel(device),
        style = MaterialTheme.typography.bodyMedium,
        modifier = modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 12.dp),
    )
}

// A device's slug, followed by the device domain in the secondary text colour.
@Composable
fun deviceLabel(device: ConnectedDevice): AnnotatedString {
    val suffixColor = MaterialTheme.colorScheme.onSurfaceVariant
    return buildAnnotatedString {
        append(device.slug)
        withStyle(SpanStyle(color = suffixColor)) { append(ConnectedDevice.DOMAIN_SUFFIX) }
    }
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
                    "device-1",
                    "100.96.0.12",
                    "fd00:2021:1111::1",
                ),
                onClick = {},
            )
            ConnectedDeviceRow(
                ConnectedDevice(
                    "2",
                    "Device 2",
                    "device-2",
                    "100.96.0.30",
                    "fd00:2021:1111::2",
                ),
                onClick = {},
            )
            ConnectedDeviceRow(
                ConnectedDevice(
                    "3",
                    "Device 3",
                    "device-3",
                    "100.96.0.41",
                    "fd00:2021:1111::3",
                ),
                onClick = {},
            )
        }
    }
}
