// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.session.ui.compose

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import dev.firezone.android.features.session.ui.ResourceUiModel

@Composable
fun DevicePoolScreen(
    pool: ResourceUiModel,
    onSelectDevice: (String) -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    BackHandler(onBack = onBack)

    Scaffold(
        modifier = modifier,
        topBar = { BackTopBar(title = pool.name, onBack = onBack) },
    ) { innerPadding ->
        Column(
            Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .verticalScroll(rememberScrollState())
                .padding(start = 16.dp, top = 0.dp, end = 16.dp, bottom = 16.dp),
        ) {
            DetailSection(label = "Connected devices") {
                if (pool.devices.isEmpty()) {
                    Text("No connected devices", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                pool.devices.forEachIndexed { index, device ->
                    if (index > 0) HorizontalDivider()
                    ConnectedDeviceRow(device = device, onClick = { onSelectDevice(device.id) })
                }
            }
        }
    }
}
