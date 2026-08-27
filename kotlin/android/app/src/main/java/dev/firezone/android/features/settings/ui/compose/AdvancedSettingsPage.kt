// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui.compose

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import dev.firezone.android.R
import dev.firezone.android.core.data.model.Config
import dev.firezone.android.core.data.model.ManagedConfigStatus

@Composable
fun AdvancedSettingsPage(
    config: Config,
    managedStatus: ManagedConfigStatus?,
    onConfigChange: (Config) -> Unit,
    onResetToDefaults: () -> Unit,
    modifier: Modifier = Modifier,
    // A parameter so the screenshot test can pin it; the build's commit changes with every push.
    buildSha: String = stringResource(R.string.git_sha),
) {
    Column(modifier.fillMaxSize()) {
        Column(
            Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            ManagedTextField(
                label = stringResource(R.string.auth_url),
                value = config.authUrl,
                isManaged = managedStatus?.isAuthUrlManaged == true,
                onValueChange = { onConfigChange(config.copy(authUrl = it)) },
            )
            ManagedTextField(
                label = stringResource(R.string.api_url),
                value = config.apiUrl,
                isManaged = managedStatus?.isApiUrlManaged == true,
                onValueChange = { onConfigChange(config.copy(apiUrl = it)) },
            )
            ManagedTextField(
                label = stringResource(R.string.log_filter),
                value = config.logFilter,
                isManaged = managedStatus?.isLogFilterManaged == true,
                onValueChange = { onConfigChange(config.copy(logFilter = it)) },
            )
            OutlinedButton(onClick = onResetToDefaults, modifier = Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.button_reset_to_defaults))
            }
        }

        Text(
            text = buildSha,
            modifier =
                Modifier
                    .align(Alignment.CenterHorizontally)
                    .padding(bottom = 16.dp),
        )
    }
}
