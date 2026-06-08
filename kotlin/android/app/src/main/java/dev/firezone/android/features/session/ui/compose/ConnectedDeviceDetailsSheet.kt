// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.session.ui.compose

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import dev.firezone.android.core.utils.ClipboardUtils
import dev.firezone.android.tunnel.model.ConnectedDevice

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConnectedDeviceDetailsSheet(
    device: ConnectedDevice,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val sheetState = rememberModalBottomSheetState()
    val context = LocalContext.current

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState, modifier = modifier) {
        Column(Modifier.fillMaxWidth().padding(16.dp)) {
            SectionLabel("Connected Device")

            DetailRow(label = "Tunnel IPv4:") {
                Text(
                    text = device.tunIpv4,
                    fontFamily = FontFamily.Monospace,
                    modifier =
                        Modifier.clickable {
                            ClipboardUtils.copyToClipboard(context, "Tunnel IPv4", device.tunIpv4)
                        },
                )
            }

            DetailRow(label = "Client ID:") {
                Text(
                    text = device.id,
                    fontFamily = FontFamily.Monospace,
                    modifier =
                        Modifier.clickable {
                            ClipboardUtils.copyToClipboard(context, "Client ID", device.id)
                        },
                )
            }

            if (device.pools.isNotEmpty()) {
                DetailRow(label = if (device.pools.size == 1) "Pool:" else "Pools:") {
                    Column {
                        device.pools.forEach { pool ->
                            Text(
                                text = pool,
                                modifier =
                                    Modifier.clickable {
                                        ClipboardUtils.copyToClipboard(context, "Pool", pool)
                                    },
                            )
                        }
                    }
                }
            }
        }
    }
}
