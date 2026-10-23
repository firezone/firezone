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
import dev.firezone.android.core.data.model.CloudRegion
import dev.firezone.android.core.data.model.Config
import dev.firezone.android.core.data.model.ManagedConfigStatus
import kotlinx.collections.immutable.toImmutableList

@Composable
fun AdvancedSettingsPage(
    config: Config,
    cloudRegion: CloudRegion,
    managedStatus: ManagedConfigStatus,
    onCloudRegionChange: (CloudRegion) -> Unit,
    onAuthUrlChange: (String) -> Unit,
    onApiUrlChange: (String) -> Unit,
    onLogFilterChange: (String) -> Unit,
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
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            ManagedDropdownField(
                label = stringResource(R.string.cloud_region),
                options = CloudRegion.entries.toImmutableList(),
                selected = cloudRegion,
                optionLabel = { stringResource(it.labelRes()) },
                isManaged = managedStatus.isAuthUrlManaged || managedStatus.isApiUrlManaged,
                onSelect = onCloudRegionChange,
            )
            if (cloudRegion == CloudRegion.CUSTOM) {
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
            ManagedTextField(
                label = stringResource(R.string.log_filter),
                value = config.logFilter,
                isManaged = managedStatus.isLogFilterManaged,
                onValueChange = onLogFilterChange,
            )
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
                    .padding(bottom = 16.dp),
        )
    }
}

private fun CloudRegion.labelRes(): Int =
    when (this) {
        CloudRegion.US -> R.string.cloud_region_us
        CloudRegion.EU -> R.string.cloud_region_eu
        CloudRegion.CUSTOM -> R.string.cloud_region_custom
    }
