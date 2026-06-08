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
    // Monospace keeps the octets aligned, but renders visually larger than the proportional resource
    // names; bodyMedium brings it back in line. The row is a single line, so it needs less vertical
    // padding than the two-line resource rows to avoid looking sparse.
    Text(
        text = device.tunIpv4,
        style = MaterialTheme.typography.bodyMedium,
        fontFamily = FontFamily.Monospace,
        modifier = modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 12.dp),
    )
}

@Preview(showBackground = true)
@Composable
private fun ConnectedDeviceRowPreview() {
    FirezoneTheme {
        Column {
            ConnectedDeviceRow(ConnectedDevice("1", "100.96.0.12", listOf("engineering")), onClick = {})
            ConnectedDeviceRow(ConnectedDevice("2", "100.96.0.30", listOf("engineering", "ops")), onClick = {})
            ConnectedDeviceRow(ConnectedDevice("3", "100.96.0.41", emptyList()), onClick = {})
        }
    }
}
