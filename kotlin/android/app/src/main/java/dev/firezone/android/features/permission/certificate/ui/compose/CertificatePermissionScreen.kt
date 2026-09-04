// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.permission.certificate.ui.compose

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview
import dev.firezone.android.R
import dev.firezone.android.features.permission.ui.compose.PermissionScreen
import dev.firezone.android.features.session.ui.compose.FirezoneTheme

/**
 * Explains why the client certificate needs picking and offers to start the selection.
 *
 * Styled and arranged like the sibling permission screens.
 */
@Composable
internal fun CertificatePermissionScreen(
    onSelectCertificate: () -> Unit,
    onSkip: () -> Unit,
    modifier: Modifier = Modifier,
) {
    PermissionScreen(
        title = R.string.device_trust_selection_title,
        description = R.string.device_trust_selection_description,
        actionLabel = R.string.device_trust_select_certificate,
        onAction = onSelectCertificate,
        onSkip = onSkip,
        modifier = modifier,
    )
}

@Preview
@Composable
private fun CertificatePermissionScreenPreview() {
    FirezoneTheme {
        CertificatePermissionScreen(
            onSelectCertificate = {},
            onSkip = {},
        )
    }
}
