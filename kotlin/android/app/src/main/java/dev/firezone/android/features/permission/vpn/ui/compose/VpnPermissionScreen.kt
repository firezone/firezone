// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.permission.vpn.ui.compose

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import dev.firezone.android.R
import dev.firezone.android.features.permission.ui.compose.PermissionScreen

@Composable
internal fun VpnPermissionScreen(
    onRequestPermission: () -> Unit,
    modifier: Modifier = Modifier,
) {
    PermissionScreen(
        title = R.string.enable_vpn_permission,
        description = R.string.vpn_permission_description,
        actionLabel = R.string.request_permission,
        onAction = onRequestPermission,
        modifier = modifier,
    )
}
