// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui.compose

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import dev.firezone.android.R
import dev.firezone.android.core.data.model.Config
import dev.firezone.android.core.data.model.ManagedConfigStatus

@Composable
fun GeneralSettingsPage(
    config: Config,
    managedStatus: ManagedConfigStatus,
    onConfigChange: (Config) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        ManagedTextField(
            label = stringResource(R.string.account_slug),
            value = config.accountSlug,
            isManaged = managedStatus.isAccountSlugManaged,
            onValueChange = { onConfigChange(config.copy(accountSlug = it)) },
        )
        ManagedSwitchRow(
            label = stringResource(R.string.start_on_login),
            checked = config.startOnLogin,
            isManaged = managedStatus.isStartOnLoginManaged,
            onCheckedChange = { onConfigChange(config.copy(startOnLogin = it)) },
        )
        ManagedSwitchRow(
            label = stringResource(R.string.connect_on_start),
            checked = config.connectOnStart,
            isManaged = managedStatus.isConnectOnStartManaged,
            onCheckedChange = { onConfigChange(config.copy(connectOnStart = it)) },
        )
    }
}
