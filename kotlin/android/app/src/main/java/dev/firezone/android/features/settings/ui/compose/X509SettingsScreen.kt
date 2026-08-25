// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui.compose

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
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
    // An alias whose key the KeyChain withholds is the personally-owned case: the administrator
    // names the certificate, yet only the user can release the key behind it, so the chooser stays
    // reachable there as well.
    val keyIsWithheld = state.alias != null && !state.isLoading && !state.isUsable
    val canSelect = keyIsWithheld || (!state.isManaged && state.alias == null)

    // An administrator's alias is not the user's to clear.
    val canForget = !state.isManaged && state.alias != null

    Column(modifier.fillMaxSize()) {
        Column(
            Modifier
                .weight(1f)
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            CertificateCard(state)

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

            state.details.forEach { field ->
                HorizontalDivider()
                DetailField(field)
            }
        }

        // The rows scroll, the buttons do not: on a certificate with a dozen rows the clear button
        // would otherwise sit below the fold.
        if (canSelect || canForget) {
            Column(
                Modifier
                    .fillMaxWidth()
                    .padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                if (canSelect) {
                    OutlinedButton(onClick = onSelectCertificate, modifier = Modifier.fillMaxWidth()) {
                        Text(stringResource(R.string.x509_select_certificate))
                    }
                }

                if (canForget) {
                    OutlinedButton(onClick = onForgetCertificate, modifier = Modifier.fillMaxWidth()) {
                        Text(stringResource(R.string.x509_forget_certificate))
                    }
                }
            }
        }
    }
}

/**
 * Names the certificate the way a browser's site-info panel names a site: what it is called, who
 * issued it and how long it lasts.
 *
 * Anything wrong with the certificate is said here as well, so that the reader has a single place
 * to look for its standing.
 */
@Composable
private fun CertificateCard(state: X509SettingsViewModel.UiState) {
    val commonName = state.details.attested(COMMON_NAME_LABEL) ?: state.details.attested(SUBJECT_LABEL)
    val issuer = state.details.attested(ISSUER_LABEL)
    val notAfter = state.details.attested(NOT_AFTER_LABEL)
    val hasProblem = state.error != null || state.unusableSummary != null

    // One line on what the certificate is for, absent while the KeyChain is still being read. The
    // wording is shared across the clients.
    val explainer =
        when {
            state.isLoading -> {
                null
            }

            state.isUsable && !hasProblem -> {
                stringResource(R.string.x509_explainer_present)
            }

            else -> {
                stringResource(R.string.x509_explainer_absent)
            }
        }

    Card(Modifier.fillMaxWidth()) {
        Row(
            Modifier.padding(16.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Icon(
                painter = painterResource(R.drawable.rounded_verified_user_black_24dp),
                contentDescription = null,
                modifier = Modifier.size(32.dp),
                tint =
                    if (hasProblem) {
                        MaterialTheme.colorScheme.error
                    } else {
                        MaterialTheme.colorScheme.onSurfaceVariant
                    },
            )

            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    text =
                        when {
                            state.alias == null -> stringResource(R.string.x509_no_certificate_title)
                            else -> commonName ?: stringResource(R.string.x509_certificate_title)
                        },
                    style = MaterialTheme.typography.titleMedium,
                )

                if (issuer != null) {
                    Text(
                        text = stringResource(R.string.x509_issued_by, issuer),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }

                if (notAfter != null) {
                    Text(
                        text = stringResource(R.string.x509_valid_until, notAfter),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }

                if (state.error != null) {
                    Notice(
                        title = stringResource(R.string.x509_error_title),
                        body = state.error,
                    )
                }

                if (state.unusableSummary != null) {
                    Notice(
                        title = stringResource(R.string.x509_unusable_title),
                        body = stringResource(R.string.x509_unusable_reason, state.unusableSummary),
                    )
                }

                if (explainer != null) {
                    Text(
                        text = explainer,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

/** How the card says that something is wrong with the certificate. */
@Composable
private fun Notice(
    title: String,
    body: String,
) {
    Column(
        Modifier.padding(top = 4.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(
            text = title,
            style = MaterialTheme.typography.titleSmall,
            color = MaterialTheme.colorScheme.error,
        )
        Text(
            text = body,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.error,
        )
        Text(
            text = stringResource(R.string.x509_contact_admin),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.error,
        )
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

/** The value of a row, `null` unless the parser read exactly one the clients will attest. */
private fun List<DetailField>.attested(label: String): String? {
    val value = firstOrNull { it.label == label }?.value

    return (value as? ClaimValue.Present)?.value
}

// Labels the Rust parser gives the rows the card is built from.
private const val COMMON_NAME_LABEL = "Common Name"
private const val SUBJECT_LABEL = "Subject"
private const val ISSUER_LABEL = "Issuer"
private const val NOT_AFTER_LABEL = "Not After"

// The rows scroll underneath a fixed button area, which needs a screen to be measured against;
// a preview that wraps its content would leave the rows no height at all.
@Preview(showSystemUi = true)
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
                            DetailField("Common Name", ClaimValue.Present("alice@example.com")),
                            DetailField("Subject", ClaimValue.Present("CN=alice@example.com")),
                            DetailField("Issuer", ClaimValue.Present("Example Corp Device CA")),
                            DetailField("Not After", ClaimValue.Present("2027-01-31 23:59:59 UTC")),
                            DetailField("Account ID", ClaimValue.Absent),
                        ),
                ),
            onSelectCertificate = {},
            onForgetCertificate = {},
        )
    }
}

@Preview(showSystemUi = true)
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
                            DetailField("Common Name", ClaimValue.Present("alice@example.com")),
                            DetailField("Issuer", ClaimValue.Present("Example Corp Device CA")),
                            DetailField("Not After", ClaimValue.Present("2024-01-31 23:59:59 UTC")),
                            DetailField("Actor Email", ClaimValue.Invalid(RejectionReason.NOT_AN_EMAIL_ADDRESS)),
                            DetailField("Account ID", ClaimValue.Absent),
                        ),
                ),
            onSelectCertificate = {},
            onForgetCertificate = {},
        )
    }
}

@Preview(showSystemUi = true)
@Composable
private fun X509SettingsScreenNoCertificatePreview() {
    FirezoneTheme {
        X509SettingsScreen(
            state = X509SettingsViewModel.UiState(),
            onSelectCertificate = {},
            onForgetCertificate = {},
        )
    }
}
