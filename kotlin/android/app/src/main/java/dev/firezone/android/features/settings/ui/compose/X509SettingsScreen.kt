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
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import dev.firezone.android.R
import dev.firezone.android.features.session.ui.compose.FirezoneTheme
import dev.firezone.android.features.settings.ui.X509SettingsViewModel
import uniffi.x509claims.ClaimValue
import uniffi.x509claims.DetailField
import uniffi.x509claims.RejectionReason

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
            text =
                stringResource(
                    if (state.isManaged) R.string.x509_managed_description else R.string.x509_user_description,
                ),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        // A managed alias the KeyChain will not release is the personally-owned case: only the user
        // can let the app have that key, so the chooser stays reachable even when the administrator
        // picked the alias.
        if (!state.isManaged || (state.alias != null && !state.isLoading && !state.isUsable)) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = onSelectCertificate) {
                    Text(stringResource(R.string.x509_select_certificate))
                }

                if (!state.isManaged && state.alias != null) {
                    TextButton(onClick = onForgetCertificate) {
                        Text(stringResource(R.string.x509_forget_certificate))
                    }
                }
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

        // The KeyChain answers a missing grant with a null key rather than an error, so this state
        // would otherwise be an alias with no detail underneath it and no reason given.
        if (state.alias != null && !state.isLoading && !state.isUsable && state.error == null) {
            Text(
                text = stringResource(R.string.x509_not_released),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

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
            Notice(
                title = stringResource(R.string.x509_error_title),
                body = state.error,
                color = MaterialTheme.colorScheme.surfaceVariant,
            )
        }

        if (state.unusableSummary != null) {
            Notice(
                title = stringResource(R.string.x509_unusable_title),
                body = stringResource(R.string.x509_unusable_reason, state.unusableSummary),
                color = MaterialTheme.colorScheme.errorContainer,
            )
        }

        state.details.forEach { field ->
            HorizontalDivider()
            DetailField(field)
        }
    }
}

/** How the screen says that something is wrong with the certificate. */
@Composable
private fun Notice(
    title: String,
    body: String,
    color: Color,
) {
    Surface(color = color, modifier = Modifier.fillMaxWidth()) {
        Column(
            Modifier.padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(text = title, style = MaterialTheme.typography.titleMedium)
            Text(text = body, style = MaterialTheme.typography.bodySmall)
            Text(
                text = stringResource(R.string.x509_contact_admin),
                style = MaterialTheme.typography.bodySmall,
            )
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

        when (val value = field.value) {
            is ClaimValue.Present -> {
                Text(
                    text = value.value,
                    style = MaterialTheme.typography.bodySmall,
                    fontFamily = FontFamily.Monospace,
                )
            }

            ClaimValue.Absent -> {
                Text(
                    text = stringResource(R.string.x509_claim_absent),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            is ClaimValue.Invalid -> {
                Text(
                    text = stringResource(R.string.x509_claim_invalid, value.reason.phrase()),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error,
                )
            }
        }
    }
}

/** The wording for a rejection, which the parser leaves to each client. */
@Composable
private fun RejectionReason.phrase(): String =
    stringResource(
        when (this) {
            RejectionReason.EMPTY -> R.string.x509_claim_empty
            RejectionReason.TOO_LONG -> R.string.x509_claim_too_long
            RejectionReason.NOT_AN_EMAIL_ADDRESS -> R.string.x509_claim_not_an_email_address
            RejectionReason.NOT_A_UUID -> R.string.x509_claim_not_a_uuid
            RejectionReason.AMBIGUOUS -> R.string.x509_claim_ambiguous
            RejectionReason.PLACEHOLDER_IDENTIFIER -> R.string.x509_claim_placeholder_identifier
            RejectionReason.UNKNOWN_ATTRIBUTE -> R.string.x509_claim_unknown_attribute
        },
    )

@Preview
@Composable
private fun X509SettingsScreenPreview() {
    FirezoneTheme {
        X509SettingsScreen(
            state =
                X509SettingsViewModel.UiState(
                    alias = "firezone-device",
                    isManaged = true,
                    isUsable = true,
                    details =
                        listOf(
                            DetailField("KeyChain Alias", ClaimValue.Present("firezone-device")),
                            DetailField("Subject", ClaimValue.Present("CN=alice@example.com")),
                            DetailField("Account ID", ClaimValue.Absent),
                        ),
                ),
            onSelectCertificate = {},
            onForgetCertificate = {},
        )
    }
}

@Preview
@Composable
private fun X509SettingsScreenUnusablePreview() {
    FirezoneTheme {
        X509SettingsScreen(
            state =
                X509SettingsViewModel.UiState(
                    alias = "firezone-device",
                    isManaged = true,
                    isUsable = true,
                    unusableSummary = "expired or not yet valid, unsupported key algorithm",
                    details =
                        listOf(
                            DetailField(
                                "Usable as a Client Identity",
                                ClaimValue.Present("No: expired or not yet valid, unsupported key algorithm"),
                            ),
                            DetailField("Actor Email", ClaimValue.Invalid(RejectionReason.NOT_AN_EMAIL_ADDRESS)),
                            DetailField("Account ID", ClaimValue.Absent),
                        ),
                ),
            onSelectCertificate = {},
            onForgetCertificate = {},
        )
    }
}
