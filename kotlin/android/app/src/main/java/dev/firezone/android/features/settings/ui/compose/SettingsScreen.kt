// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui.compose

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import dev.firezone.android.BuildConfig
import dev.firezone.android.R
import dev.firezone.android.core.data.model.Config
import dev.firezone.android.core.data.model.ManagedConfigStatus
import dev.firezone.android.core.data.model.Portal
import dev.firezone.android.core.data.model.SignInConfig
import dev.firezone.android.features.session.ui.compose.BackTopBar
import dev.firezone.android.features.settings.ui.DeviceTrustSettingsViewModel
import dev.firezone.android.ui.FirezoneIcons
import kotlinx.coroutines.launch

/** A settings page and how the title and navigation bar name it. */
internal enum class SettingsPage(
    val labelRes: Int,
    val icon: ImageVector,
) {
    GENERAL(R.string.settings_title, FirezoneIcons.DiscoverTune),
    DEVICE_TRUST(R.string.device_trust_settings_title, FirezoneIcons.VerifiedUser),
    LOGS(R.string.diagnostics_settings_title, FirezoneIcons.Description),
}

/** The pages to show, in order. */
internal fun settingsPages(showDeviceTrust: Boolean): List<SettingsPage> =
    buildList {
        add(SettingsPage.GENERAL)

        if (showDeviceTrust) {
            add(SettingsPage.DEVICE_TRUST)
        }

        add(SettingsPage.LOGS)
    }

@Composable
internal fun SettingsScreen(
    config: Config,
    portal: Portal,
    managedStatus: ManagedConfigStatus,
    logSizeBytes: Long,
    deviceTrustState: DeviceTrustSettingsViewModel.UiState,
    showDeviceTrust: Boolean,
    signedInWith: SignInConfig?,
    onPortalChange: (Portal) -> Unit,
    onAuthUrlChange: (String) -> Unit,
    onApiUrlChange: (String) -> Unit,
    onLogFilterChange: (String) -> Unit,
    onAccountSlugChange: (String) -> Unit,
    onStartOnLoginChange: (Boolean) -> Unit,
    onConnectOnStartChange: (Boolean) -> Unit,
    onResetToDefaults: () -> Unit,
    onClearLogs: () -> Unit,
    onExportLogs: () -> Unit,
    onLogsShown: () -> Unit,
    onSelectCertificate: () -> Unit,
    onDeviceTrustShown: () -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    // Parameters so the screenshot test can pin them; the build's commit changes with every push.
    versionName: String = BuildConfig.VERSION_NAME,
    buildSha: String = stringResource(R.string.git_sha),
) {
    val pages = remember(showDeviceTrust) { settingsPages(showDeviceTrust) }
    val pagerState = rememberPagerState(pageCount = { pages.size })
    val scope = rememberCoroutineScope()
    var showResetConfirmation by rememberSaveable { mutableStateOf(false) }

    // Revoking the certificate drops a page, so the index can outrun the list for a frame.
    val currentPage = pages.getOrNull(pagerState.currentPage)

    // The log directory grows while the app runs, and an administrator can install or revoke the
    // certificate, so both are re-read each time their page is shown.
    LaunchedEffect(currentPage) {
        if (currentPage == SettingsPage.LOGS) onLogsShown()
        if (currentPage == SettingsPage.DEVICE_TRUST) onDeviceTrustShown()
    }

    Scaffold(
        modifier = modifier,
        topBar = {
            BackTopBar(
                title = stringResource((currentPage ?: SettingsPage.GENERAL).labelRes),
                onBack = onBack,
                actions = {
                    if (currentPage == SettingsPage.GENERAL) {
                        OverflowMenu(onResetToDefaults = { showResetConfirmation = true })
                    }
                },
            )
        },
        bottomBar = {
            // The tabs jump without smooth scrolling, so that crossing the bar does not drag
            // every page in between across the screen.
            NavigationBar(containerColor = MaterialTheme.colorScheme.background) {
                pages.forEachIndexed { index, page ->
                    NavigationBarItem(
                        selected = pagerState.currentPage == index,
                        onClick = { scope.launch { pagerState.scrollToPage(index) } },
                        icon = { Icon(imageVector = page.icon, contentDescription = null) },
                        label = { Text(stringResource(page.labelRes)) },
                    )
                }
            }
        },
    ) { innerPadding ->
        HorizontalPager(state = pagerState, modifier = Modifier.fillMaxSize().padding(innerPadding)) { page ->
            when (pages[page]) {
                SettingsPage.GENERAL -> {
                    GeneralSettingsPage(
                        config = config,
                        portal = portal,
                        managedStatus = managedStatus,
                        signedInWith = signedInWith,
                        onPortalChange = onPortalChange,
                        onAuthUrlChange = onAuthUrlChange,
                        onApiUrlChange = onApiUrlChange,
                        onAccountSlugChange = onAccountSlugChange,
                        onStartOnLoginChange = onStartOnLoginChange,
                        onConnectOnStartChange = onConnectOnStartChange,
                    )
                }

                SettingsPage.DEVICE_TRUST -> {
                    DeviceTrustSettingsScreen(
                        state = deviceTrustState,
                        onSelectCertificate = onSelectCertificate,
                    )
                }

                SettingsPage.LOGS -> {
                    LogSettingsPage(
                        config = config,
                        managedStatus = managedStatus,
                        logSizeBytes = logSizeBytes,
                        onLogFilterChange = onLogFilterChange,
                        onClearLogs = onClearLogs,
                        onExportLogs = onExportLogs,
                        versionName = versionName,
                        buildSha = buildSha,
                    )
                }
            }
        }
    }

    if (showResetConfirmation) {
        AlertDialog(
            onDismissRequest = { showResetConfirmation = false },
            title = { Text(stringResource(R.string.reset_to_defaults_confirm_title)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        showResetConfirmation = false
                        onResetToDefaults()
                    },
                ) {
                    Text(stringResource(R.string.reset_to_defaults_confirm))
                }
            },
            dismissButton = {
                TextButton(onClick = { showResetConfirmation = false }) {
                    Text(stringResource(android.R.string.cancel))
                }
            },
        )
    }
}

@Composable
private fun OverflowMenu(onResetToDefaults: () -> Unit) {
    var expanded by remember { mutableStateOf(false) }

    Box {
        IconButton(onClick = { expanded = true }) {
            Icon(imageVector = FirezoneIcons.MoreVert, contentDescription = stringResource(R.string.more_options))
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.reset_to_defaults)) },
                onClick = {
                    expanded = false
                    onResetToDefaults()
                },
            )
        }
    }
}
