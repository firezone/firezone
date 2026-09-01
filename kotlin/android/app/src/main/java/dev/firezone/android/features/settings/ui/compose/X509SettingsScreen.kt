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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
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
import androidx.compose.ui.unit.em
import dev.firezone.android.R
import dev.firezone.android.features.session.ui.compose.FirezoneTheme
import dev.firezone.android.features.settings.ui.X509SettingsViewModel
import uniffi.x509claims.DetailField
import uniffi.x509claims.ValidationError

/**
 * Shows which client certificate this device presents for device trust and what it contains.
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

    // An administrator's alias is not the user's to clear, and neither is one whose key is still
    // withheld: that screen asks for a grant, and offering to forget the certificate in the same
    // breath asks the reader to both make a selection and undo one.
    val canForget = !state.isManaged && state.alias != null && !keyIsWithheld

    Column(
        modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        CertificateCard(state)

        // The KeyChain answers a missing grant with a null key rather than an error, so this state
        // would otherwise be a card naming a certificate with nothing underneath it to say why.
        if (keyIsWithheld && state.error == null) {
            WarningBanner(stringResource(R.string.x509_not_released))
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

        // Under the card when there is nothing to say about a certificate, under the rows when
        // there is: either way the button follows what it acts on.
        if (keyIsWithheld) {
            SettingsButton(
                text = stringResource(R.string.x509_select_certificate),
                onClick = onSelectCertificate,
            )
        }

        if (canForget) {
            SettingsButton(
                text = stringResource(R.string.x509_forget_certificate),
                onClick = onForgetCertificate,
            )
        }
    }
}

/**
 * An outlined button drawn the way the other settings tabs draw theirs.
 *
 * Those are `Widget.MaterialComponents.Button.OutlinedButton` in XML, which is squarer than the
 * Material 3 default and letters its label in upper case.
 */
@Composable
private fun SettingsButton(
    text: String,
    onClick: () -> Unit,
) {
    OutlinedButton(
        onClick = onClick,
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(4.dp),
        colors =
            ButtonDefaults.outlinedButtonColors(
                contentColor = MaterialTheme.colorScheme.onSurface,
            ),
    ) {
        Text(
            text = text.uppercase(),
            style = MaterialTheme.typography.labelLarge,
            letterSpacing = 0.09.em,
        )
    }
}

/** Says that the reader has something to do, rather than leaving it as one more line of prose. */
@Composable
private fun WarningBanner(text: String) {
    Card(
        Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.errorContainer),
    ) {
        Row(
            Modifier.padding(12.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Icon(
                painter = painterResource(R.drawable.info_24px),
                contentDescription = null,
                modifier = Modifier.size(20.dp),
                tint = MaterialTheme.colorScheme.onErrorContainer,
            )

            Text(
                text = text,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onErrorContainer,
            )
        }
    }
}

/**
 * Names the certificate the way a browser's site-info panel names a site: what it is called, who
 * issued it and how long it lasts.
 */
@Composable
private fun CertificateCard(state: X509SettingsViewModel.UiState) {
    val commonName = state.details.valueOf(COMMON_NAME_LABEL) ?: state.details.valueOf(SUBJECT_LABEL)
    val issuer = state.details.valueOf(ISSUER_LABEL)
    val notAfter = state.details.valueOf(NOT_AFTER_LABEL)
    val readFailure =
        when {
            state.error != null -> state.error
            state.certificateIsUnreadable -> stringResource(R.string.x509_unreadable)
            else -> null
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
                    if (readFailure != null) {
                        MaterialTheme.colorScheme.error
                    } else {
                        MaterialTheme.colorScheme.onSurfaceVariant
                    },
            )

            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    text = commonName ?: stringResource(R.string.x509_certificate_title),
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

                if (readFailure != null) {
                    Notice(
                        title = stringResource(R.string.x509_error_title),
                        body = readFailure,
                    )
                }
            }
        }
    }
}

/** How the card says that the certificate could not be read. */
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

        val value = field.value

        if (value != null) {
            Text(
                text = value,
                style = MaterialTheme.typography.bodySmall,
                fontFamily = FontFamily.Monospace,
            )
        } else {
            Text(
                text = stringResource(R.string.x509_claim_absent),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        field.problem?.let { problem -> ClaimProblem(problem) }
    }
}

/** Reads underneath the value it belongs to, the way a form shows an error on its input. */
@Composable
private fun ClaimProblem(error: ValidationError) {
    Text(
        text = stringResource(error.phrase()),
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.error,
    )
}

/** The string resource wording a problem, which the parser leaves to each client. */
private fun ValidationError.phrase(): Int =
    when (this) {
        ValidationError.EMPTY -> R.string.x509_claim_empty
        ValidationError.TOO_LONG -> R.string.x509_claim_too_long
        ValidationError.AMBIGUOUS -> R.string.x509_claim_ambiguous
        ValidationError.PLACEHOLDER_IDENTIFIER -> R.string.x509_claim_placeholder_identifier
        ValidationError.UNKNOWN_ATTRIBUTE -> R.string.x509_claim_unknown_attribute
        ValidationError.NOT_YET_VALID -> R.string.x509_claim_not_yet_valid
        ValidationError.EXPIRED -> R.string.x509_claim_expired
        ValidationError.MISSING_CLIENT_AUTH_EKU -> R.string.x509_claim_missing_client_auth_eku
        ValidationError.DIGITAL_SIGNATURE_NOT_ALLOWED -> R.string.x509_claim_digital_signature_not_allowed
    }

private fun List<DetailField>.valueOf(label: String): String? = firstOrNull { it.label == label }?.value

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
                            DetailField("Common Name", "firezone-device", null),
                            DetailField("Subject", "CN=firezone-device, O=Example Corp", null),
                            DetailField("Issuer", "CN=Example Corp Device CA, O=Example Corp", null),
                            DetailField("Not After", "2027-01-31 23:59:59 UTC", null),
                        ),
                ),
            onSelectCertificate = {},
            onForgetCertificate = {},
        )
    }
}
