// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui.compose

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import dev.firezone.android.R

@Composable
fun DeveloperSettingsPage(
    forceRelayedConnections: Boolean,
    onForceRelayedConnectionsChange: (Boolean) -> Unit,
    onResetConnlib: () -> Unit,
    onHide: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        SettingsGroup {
            SettingsRow(
                title = stringResource(R.string.reset_connlib),
                action = Modifier.clickable(role = Role.Button, onClick = onResetConnlib),
            )
            SwitchPreferenceRow(
                title = stringResource(R.string.force_relayed_connections),
                checked = forceRelayedConnections,
                isManaged = false,
                onCheckedChange = onForceRelayedConnectionsChange,
            )
            SettingsRow(
                title = stringResource(R.string.hide_developer_settings),
                action = Modifier.clickable(role = Role.Button, onClick = onHide),
            )
        }
    }
}
