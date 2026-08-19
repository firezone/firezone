// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui.compose

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import dev.firezone.android.R
import dev.firezone.android.features.session.ui.compose.FirezoneTheme
import dev.firezone.android.features.settings.ui.X509SettingsViewModel
import uniffi.x509claims.DetailField

/**
 * Shows which client certificate this device signs in with and what it contains.
 *
 * The screen is read-only when an administrator dictates the certificate, which is the case on
 * managed devices; otherwise the user picks one from the system KeyChain.
 */
@Composable
internal fun X509SettingsScreen(
    state: X509SettingsViewModel.UiState,
    onSelectCertificate: () -> Unit,
    onForgetCertificate: () -> Unit,
    onRefresh: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            text = stringResource(R.string.x509_claims_title),
            style = MaterialTheme.typography.titleLarge,
        )
        Text(
            text = stringResource(R.string.x509_claims_description),
            style = MaterialTheme.typography.bodyMedium,
        )
        Text(
            text =
                stringResource(
                    if (state.isManaged) R.string.x509_managed_description else R.string.x509_user_description,
                ),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (!state.isManaged) {
                Button(onClick = onSelectCertificate) {
                    Text(stringResource(R.string.x509_select_certificate))
                }

                if (state.alias != null) {
                    TextButton(onClick = onForgetCertificate) {
                        Text(stringResource(R.string.x509_forget_certificate))
                    }
                }
            }

            OutlinedButton(onClick = onRefresh, enabled = !state.isLoading) {
                Text(stringResource(R.string.x509_refresh))
            }
        }

        Text(
            text =
                if (state.alias == null) {
                    stringResource(R.string.x509_not_configured)
                } else {
                    stringResource(R.string.x509_alias_configured, state.alias)
                },
            style = MaterialTheme.typography.bodyMedium,
        )

        if (state.isLoading) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                Text(
                    text = stringResource(R.string.x509_loading),
                    style = MaterialTheme.typography.bodySmall,
                )
            }
        }

        if (state.error != null) {
            Surface(
                color = MaterialTheme.colorScheme.surfaceVariant,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(
                    Modifier.padding(12.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(
                        text = stringResource(R.string.x509_error_title),
                        style = MaterialTheme.typography.titleMedium,
                    )
                    Text(text = state.error, style = MaterialTheme.typography.bodySmall)
                    Text(
                        text = stringResource(R.string.x509_contact_admin),
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
        }

        state.details.forEach { field ->
            HorizontalDivider()
            DetailField(field)
        }
    }
}

@Composable
private fun DetailField(field: DetailField) {
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(
            text = field.label,
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(
            text = field.value,
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
        )
    }
}

@Preview
@Composable
private fun X509SettingsScreenPreview() {
    FirezoneTheme {
        X509SettingsScreen(
            state =
                X509SettingsViewModel.UiState(
                    alias = "firezone-device",
                    isManaged = true,
                    details =
                        listOf(
                            DetailField("KeyChain Alias", "firezone-device"),
                            DetailField("Subject", "CN=alice@example.com"),
                        ),
                ),
            onSelectCertificate = {},
            onForgetCertificate = {},
            onRefresh = {},
        )
    }
}
