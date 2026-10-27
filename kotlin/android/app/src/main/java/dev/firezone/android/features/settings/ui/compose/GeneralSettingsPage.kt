// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui.compose

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import dev.firezone.android.R
import dev.firezone.android.core.data.model.Config
import dev.firezone.android.core.data.model.ManagedConfigStatus
import dev.firezone.android.core.data.model.Portal
import dev.firezone.android.core.data.model.SignInSettings
import dev.firezone.android.core.data.model.signInSettings
import dev.firezone.android.features.settings.ui.isValidApiUrl
import dev.firezone.android.features.settings.ui.isValidAuthUrl
import kotlinx.collections.immutable.toImmutableList

@Composable
fun GeneralSettingsPage(
    config: Config,
    portal: Portal,
    managedStatus: ManagedConfigStatus,
    signedInWith: SignInSettings?,
    onPortalChange: (Portal) -> Unit,
    onAuthUrlChange: (String) -> Unit,
    onApiUrlChange: (String) -> Unit,
    onAccountSlugChange: (String) -> Unit,
    onStartOnLoginChange: (Boolean) -> Unit,
    onConnectOnStartChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        // While signed in, values that differ from the session's own only apply at the next sign-in.
        val signInChangeNote = stringResource(R.string.sign_in_change_note).takeIf { signedInWith != null }

        Column {
            SettingsGroup(title = stringResource(R.string.settings_section_sign_in)) {
                TextPreferenceRow(
                    title = stringResource(R.string.account_slug),
                    value = config.accountSlug,
                    isManaged = managedStatus.isAccountSlugManaged,
                    onValueChange = onAccountSlugChange,
                    note = { slug -> signInChangeNote?.takeIf { slug != signedInWith?.accountSlug } },
                )
                // There are no managed keys for the portal: managed URLs decide it.
                ChoicePreferenceRow(
                    title = stringResource(R.string.portal),
                    options = Portal.entries.toImmutableList(),
                    selected = portal,
                    optionLabel = { stringResource(it.labelRes()) },
                    isManaged = managedStatus.isAuthUrlManaged || managedStatus.isApiUrlManaged,
                    onSelect = onPortalChange,
                    note = signInChangeNote,
                )
                if (portal == Portal.CUSTOM) {
                    TextPreferenceRow(
                        title = stringResource(R.string.auth_url),
                        value = config.authUrl,
                        isManaged = managedStatus.isAuthUrlManaged,
                        onValueChange = onAuthUrlChange,
                        errorMessage = { if (isValidAuthUrl(it)) null else stringResource(R.string.auth_url_invalid) },
                        note = { url -> signInChangeNote?.takeIf { url != signedInWith?.authUrl } },
                    )
                    TextPreferenceRow(
                        title = stringResource(R.string.api_url),
                        value = config.apiUrl,
                        isManaged = managedStatus.isApiUrlManaged,
                        onValueChange = onApiUrlChange,
                        errorMessage = { if (isValidApiUrl(it)) null else stringResource(R.string.api_url_invalid) },
                        note = { url -> signInChangeNote?.takeIf { url != signedInWith?.apiUrl } },
                    )
                }
            }
            if (signInChangeNote != null && config.signInSettings() != signedInWith) {
                Text(
                    signInChangeNote,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(start = 16.dp, top = 8.dp, end = 16.dp),
                )
            }
        }
        SettingsGroup(title = stringResource(R.string.settings_section_startup)) {
            SwitchPreferenceRow(
                title = stringResource(R.string.start_on_login),
                checked = config.startOnLogin,
                isManaged = managedStatus.isStartOnLoginManaged,
                onCheckedChange = onStartOnLoginChange,
            )
            SwitchPreferenceRow(
                title = stringResource(R.string.connect_on_start),
                checked = config.connectOnStart,
                isManaged = managedStatus.isConnectOnStartManaged,
                onCheckedChange = onConnectOnStartChange,
            )
        }
    }
}

private fun Portal.labelRes(): Int =
    when (this) {
        Portal.CLOUD_US -> R.string.portal_cloud_us
        Portal.CLOUD_EU -> R.string.portal_cloud_eu
        Portal.CUSTOM -> R.string.portal_custom
    }
