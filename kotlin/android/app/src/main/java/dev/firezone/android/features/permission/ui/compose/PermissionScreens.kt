// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.permission.ui.compose

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import dev.firezone.android.R

@Composable
fun VpnPermissionScreen(
    onRequestPermission: () -> Unit,
    modifier: Modifier = Modifier,
) {
    PermissionScreen(
        title = stringResource(R.string.enable_vpn_permission),
        description = stringResource(R.string.vpn_permission_description),
        onRequestPermission = onRequestPermission,
        modifier = modifier,
    )
}

@Composable
fun NotificationPermissionScreen(
    onRequestPermission: () -> Unit,
    onSkip: () -> Unit,
    modifier: Modifier = Modifier,
) {
    PermissionScreen(
        title = stringResource(R.string.enable_notification_permission),
        description = stringResource(R.string.notification_permission_description),
        onRequestPermission = onRequestPermission,
        modifier = modifier,
        onSkip = onSkip,
    )
}

@Composable
private fun PermissionScreen(
    title: String,
    description: String,
    onRequestPermission: () -> Unit,
    modifier: Modifier = Modifier,
    onSkip: (() -> Unit)? = null,
) {
    Scaffold(modifier = modifier) { innerPadding ->
        Column(
            Modifier.fillMaxSize().padding(innerPadding).padding(16.dp),
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Image(
                painter = painterResource(R.drawable.ic_firezone_logo),
                contentDescription = null,
                modifier = Modifier.size(120.dp),
            )
            Text(text = stringResource(R.string.app_short_name), style = MaterialTheme.typography.displaySmall)

            Spacer(Modifier.height(48.dp))

            Text(text = title, style = MaterialTheme.typography.headlineSmall, textAlign = TextAlign.Center)

            Spacer(Modifier.height(16.dp))

            Text(text = description, textAlign = TextAlign.Center)

            Spacer(Modifier.height(24.dp))

            Button(onClick = onRequestPermission, modifier = Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.request_permission))
            }
            if (onSkip != null) {
                // M3 labels text buttons with `primary`, which the brand makes orange.
                TextButton(
                    onClick = onSkip,
                    modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.onSurfaceVariant),
                ) {
                    Text(stringResource(R.string.skip))
                }
            }
        }
    }
}
