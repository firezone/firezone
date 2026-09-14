// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.permission.notification.ui.compose

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import dev.firezone.android.R
import dev.firezone.android.features.permission.ui.compose.PermissionScreen

@Composable
internal fun NotificationPermissionScreen(
    onRequestPermission: () -> Unit,
    onSkip: () -> Unit,
    modifier: Modifier = Modifier,
) {
    PermissionScreen(
        title = R.string.enable_notification_permission,
        description = R.string.notification_permission_description,
        actionLabel = R.string.request_permission,
        onAction = onRequestPermission,
        onSkip = onSkip,
        modifier = modifier,
    )
}
