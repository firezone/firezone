// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui.compose

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withLink
import androidx.compose.ui.unit.dp
import dev.firezone.android.R
import dev.firezone.android.core.data.model.Config
import dev.firezone.android.core.data.model.ManagedConfigStatus
import dev.firezone.android.core.data.model.Portal
import kotlinx.collections.immutable.toImmutableList

@Composable
fun GeneralSettingsPage(
    config: Config,
    portal: Portal,
    managedStatus: ManagedConfigStatus,
    onPortalChange: (Portal) -> Unit,
    onAuthUrlChange: (String) -> Unit,
    onApiUrlChange: (String) -> Unit,
    onAccountSlugChange: (String) -> Unit,
    onStartOnLoginChange: (Boolean) -> Unit,
    onConnectOnStartChange: (Boolean) -> Unit,
    onResetToDefaults: () -> Unit,
    modifier: Modifier = Modifier,
    // A parameter so the screenshot test can pin it; the build's commit changes with every push.
    buildSha: String = stringResource(R.string.git_sha),
) {
    Column(modifier.fillMaxSize()) {
        Column(
            Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState())
                .padding(start = 16.dp, top = 4.dp, end = 16.dp, bottom = 8.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            SettingsSection(stringResource(R.string.settings_section_sign_in)) {
                ManagedTextField(
                    label = stringResource(R.string.account_slug),
                    value = config.accountSlug,
                    isManaged = managedStatus.isAccountSlugManaged,
                    onValueChange = onAccountSlugChange,
                )
                // There are no managed keys for the portal: managed URLs decide it.
                ManagedDropdownField(
                    label = stringResource(R.string.portal),
                    options = Portal.entries.toImmutableList(),
                    selected = portal,
                    optionLabel = { stringResource(it.labelRes()) },
                    isManaged = managedStatus.isAuthUrlManaged || managedStatus.isApiUrlManaged,
                    onSelect = onPortalChange,
                )
                if (portal == Portal.CUSTOM) {
                    ManagedTextField(
                        label = stringResource(R.string.auth_url),
                        value = config.authUrl,
                        isManaged = managedStatus.isAuthUrlManaged,
                        onValueChange = onAuthUrlChange,
                    )
                    ManagedTextField(
                        label = stringResource(R.string.api_url),
                        value = config.apiUrl,
                        isManaged = managedStatus.isApiUrlManaged,
                        onValueChange = onApiUrlChange,
                    )
                }
            }
            SettingsSection(stringResource(R.string.settings_section_startup), Modifier.padding(top = 4.dp)) {
                ManagedSwitchRow(
                    label = stringResource(R.string.start_on_login),
                    checked = config.startOnLogin,
                    isManaged = managedStatus.isStartOnLoginManaged,
                    onCheckedChange = onStartOnLoginChange,
                )
                ManagedSwitchRow(
                    label = stringResource(R.string.connect_on_start),
                    checked = config.connectOnStart,
                    isManaged = managedStatus.isConnectOnStartManaged,
                    onCheckedChange = onConnectOnStartChange,
                )
            }
            OutlinedButton(onClick = onResetToDefaults, modifier = Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.button_reset_to_defaults))
            }
        }

        val linkColor = MaterialTheme.colorScheme.primary
        Text(
            text =
                buildAnnotatedString {
                    append("Build: ")
                    if (buildSha == "unknown") {
                        append(buildSha)
                    } else {
                        withLink(
                            LinkAnnotation.Url(
                                "https://github.com/firezone/firezone/commit/$buildSha",
                                TextLinkStyles(
                                    SpanStyle(
                                        color = linkColor,
                                        textDecoration = TextDecoration.Underline,
                                    ),
                                ),
                            ),
                        ) {
                            append(buildSha.take(8))
                        }
                    }
                },
            modifier =
                Modifier
                    .align(Alignment.CenterHorizontally)
                    .padding(bottom = 8.dp),
        )
    }
}

private fun Portal.labelRes(): Int =
    when (this) {
        Portal.CLOUD_US -> R.string.portal_cloud_us
        Portal.CLOUD_EU -> R.string.portal_cloud_eu
        Portal.CUSTOM -> R.string.portal_custom
    }
