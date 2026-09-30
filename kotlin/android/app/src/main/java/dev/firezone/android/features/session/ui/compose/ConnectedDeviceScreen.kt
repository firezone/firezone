// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.session.ui.compose

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import dev.firezone.android.core.utils.ClipboardUtils
import dev.firezone.android.tunnel.model.ConnectedDevice

@Composable
fun ConnectedDeviceScreen(
    device: ConnectedDevice,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    BackHandler(onBack = onBack)
    val context = LocalContext.current

    Scaffold(
        modifier = modifier,
        topBar = { BackTopBar(title = device.slug, onBack = onBack) },
    ) { innerPadding ->
        Column(
            Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .verticalScroll(rememberScrollState())
                .padding(start = 16.dp, top = 0.dp, end = 16.dp, bottom = 16.dp),
        ) {
            DetailSection(label = "Domain") {
                Text(
                    text = deviceLabel(device),
                    modifier =
                        Modifier.clickable {
                            ClipboardUtils.copyToClipboard(context, "Device Domain", device.domain)
                        },
                )
            }

            DetailSection(label = "Name") {
                Text(
                    text = device.name,
                    modifier =
                        Modifier.clickable {
                            ClipboardUtils.copyToClipboard(context, "Client Name", device.name)
                        },
                )
            }

            DetailSection(label = "Tunnel IPs") {
                Text(
                    text = device.tunIpv4,
                    fontFamily = FontFamily.Monospace,
                    modifier =
                        Modifier.clickable {
                            ClipboardUtils.copyToClipboard(context, "Tunnel IPv4", device.tunIpv4)
                        },
                )
                Text(
                    text = device.tunIpv6,
                    fontFamily = FontFamily.Monospace,
                    modifier =
                        Modifier.clickable {
                            ClipboardUtils.copyToClipboard(context, "Tunnel IPv6", device.tunIpv6)
                        },
                )
            }

            DetailSection(label = "Client ID") {
                Text(
                    text = device.id,
                    fontFamily = FontFamily.Monospace,
                    modifier =
                        Modifier.clickable {
                            ClipboardUtils.copyToClipboard(context, "Client ID", device.id)
                        },
                )
            }
        }
    }
}
