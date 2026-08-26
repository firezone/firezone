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
import uniffi.x509claims.ClaimValue
import uniffi.x509claims.DetailField
import uniffi.x509claims.FieldProblem
import uniffi.x509claims.RejectionReason
import uniffi.x509claims.UnusableReason

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
        if (canSelect) {
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
 *
 * Anything wrong with the certificate is said here as well, so that the reader has a single place
 * to look for its standing.
 */
@Composable
private fun CertificateCard(state: X509SettingsViewModel.UiState) {
    val commonName = state.details.attested(COMMON_NAME_LABEL) ?: state.details.attested(SUBJECT_LABEL)
    val issuer = state.details.attested(ISSUER_LABEL)
    val notAfter = state.details.attested(NOT_AFTER_LABEL)
    val hasProblem = state.error != null || !state.certificateIsUsable

    val isAttesting = state.isUsable && !state.isLoading && !hasProblem

    // One line on what the certificate is for, absent while the KeyChain is still being read. The
    // wording is shared across the clients.
    //
    // A certificate that was read and cannot be used says so rather than reading as one that was
    // never found: the rows below carry the attribute that makes it unusable.
    val explainer =
        when {
            state.isLoading -> {
                null
            }

            isAttesting -> {
                stringResource(R.string.x509_explainer_present)
            }

            !state.certificateIsUsable -> {
                stringResource(R.string.x509_explainer_unusable)
            }

            else -> {
                stringResource(R.string.x509_explainer_absent)
            }
        }

    Card(Modifier.fillMaxWidth()) {
        Column(
            Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
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

                    // Only the rules no row shows: the rest read underneath the attribute they are
                    // about, and repeating them here would say the same thing twice.
                    if (state.certificateProblems.isNotEmpty()) {
                        val sentences = state.certificateProblems.map { stringResource(it.sentence()) }
                        Notice(
                            title = stringResource(R.string.x509_unusable_title),
                            body = sentences.joinToString(" "),
                        )
                    }
                }
            }

            // Outside the row so it reads across the whole card rather than starting where the
            // text beside the icon does: it is about the certificate, not about any one field.
            if (explainer != null) {
                Row(
                    Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    if (isAttesting) {
                        Icon(
                            painter = painterResource(R.drawable.rounded_check_circle_24),
                            contentDescription = null,
                            modifier = Modifier.size(16.dp),
                            tint = MaterialTheme.colorScheme.primary,
                        )
                    }

                    Text(
                        text = explainer,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.weight(1f),
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
        }

        field.problem?.let { problem -> FieldProblem(problem) }
    }
}

/** Reads underneath the value it belongs to, the way a form shows an error on its input. */
@Composable
private fun FieldProblem(problem: FieldProblem) {
    Text(
        text =
            when (problem) {
                is FieldProblem.Rejected -> {
                    stringResource(R.string.x509_claim_invalid, stringResource(problem.reason.phrase()))
                }

                is FieldProblem.Unusable -> {
                    stringResource(problem.reason.sentence())
                }
            },
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.error,
    )
}

/** The string resource wording a rejection, which the parser leaves to each client. */
private fun RejectionReason.phrase(): Int =
    when (this) {
        RejectionReason.EMPTY -> R.string.x509_claim_empty
        RejectionReason.TOO_LONG -> R.string.x509_claim_too_long
        RejectionReason.NOT_AN_EMAIL_ADDRESS -> R.string.x509_claim_not_an_email_address
        RejectionReason.NOT_A_UUID -> R.string.x509_claim_not_a_uuid
        RejectionReason.AMBIGUOUS -> R.string.x509_claim_ambiguous
        RejectionReason.PLACEHOLDER_IDENTIFIER -> R.string.x509_claim_placeholder_identifier
        RejectionReason.UNKNOWN_ATTRIBUTE -> R.string.x509_claim_unknown_attribute
    }

/** The string resource wording a rule the certificate fails, which the parser leaves to each client. */
private fun UnusableReason.sentence(): Int =
    when (this) {
        UnusableReason.NO_CLIENT_AUTH_EKU -> R.string.x509_rule_no_client_auth_eku
        UnusableReason.NO_DIGITAL_SIGNATURE_KEY_USAGE -> R.string.x509_rule_no_digital_signature_key_usage
        UnusableReason.NOT_YET_VALID -> R.string.x509_rule_not_yet_valid
        UnusableReason.EXPIRED -> R.string.x509_rule_expired
        UnusableReason.UNSUPPORTED_KEY_ALGORITHM -> R.string.x509_rule_unsupported_key_algorithm
    }

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
                            DetailField("Common Name", ClaimValue.Present("alice@example.com"), null),
                            DetailField("Subject", ClaimValue.Present("CN=alice@example.com"), null),
                            DetailField("Issuer", ClaimValue.Present("Example Corp Device CA"), null),
                            DetailField("Not After", ClaimValue.Present("2027-01-31 23:59:59 UTC"), null),
                            DetailField("Account ID", ClaimValue.Absent, null),
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
                    certificateIsUsable = false,
                    certificateProblems = listOf(UnusableReason.NO_CLIENT_AUTH_EKU),
                    // The parser reads the rows with a problem first.
                    details =
                        listOf(
                            DetailField(
                                "Not After",
                                ClaimValue.Present("2024-01-31 23:59:59 UTC"),
                                FieldProblem.Unusable(UnusableReason.EXPIRED),
                            ),
                            DetailField(
                                "Actor Email",
                                ClaimValue.Present("alice(at)example.com"),
                                FieldProblem.Rejected(RejectionReason.NOT_AN_EMAIL_ADDRESS),
                            ),
                            DetailField("Account ID", ClaimValue.Absent, FieldProblem.Rejected(RejectionReason.EMPTY)),
                            DetailField("Common Name", ClaimValue.Present("alice@example.com"), null),
                            DetailField("Issuer", ClaimValue.Present("Example Corp Device CA"), null),
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
