// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui.compose

import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import dev.firezone.android.R
import dev.firezone.android.core.data.model.Config
import dev.firezone.android.core.data.model.ManagedConfigStatus
import dev.firezone.android.features.settings.ui.DeviceTrustSettingsViewModel
import kotlinx.coroutines.launch

/** A settings page and how the navigation bar names it. */
internal enum class SettingsPage(
    val labelRes: Int,
    val iconRes: Int,
) {
    GENERAL(R.string.general_settings_title, R.drawable.rounded_discover_tune_black_24dp),
    ADVANCED(R.string.advanced_settings_title, R.drawable.rounded_settings_black_24dp),
    DEVICE_TRUST(R.string.device_trust_settings_title, R.drawable.rounded_verified_user_black_24dp),
    LOGS(R.string.log_settings_title, R.drawable.rounded_description_black_24dp),
}

/** The pages to show, in order. */
internal fun settingsPages(hasConfiguredCertificateAlias: Boolean): List<SettingsPage> =
    buildList {
        add(SettingsPage.GENERAL)
        add(SettingsPage.ADVANCED)

        if (hasConfiguredCertificateAlias) {
            add(SettingsPage.DEVICE_TRUST)
        }

        add(SettingsPage.LOGS)
    }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun SettingsScreen(
    config: Config,
    managedStatus: ManagedConfigStatus,
    isSaveEnabled: Boolean,
    logSizeBytes: Long,
    deviceTrustState: DeviceTrustSettingsViewModel.UiState,
    hasConfiguredCertificateAlias: Boolean,
    warnBeforeSaving: Boolean,
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
    onForgetCertificate: () -> Unit,
    onDeviceTrustShown: () -> Unit,
    onSave: () -> Unit,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
    buildSha: String = stringResource(R.string.git_sha),
) {
    val pages = remember(hasConfiguredCertificateAlias) { settingsPages(hasConfiguredCertificateAlias) }
    val pagerState = rememberPagerState(pageCount = { pages.size })
    val scope = rememberCoroutineScope()
    var showSaveWarning by rememberSaveable { mutableStateOf(false) }

    // Forgetting the certificate drops a page, so the index can outrun the list for a frame.
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
            CenterAlignedTopAppBar(
                // M3 defaults the bar to `surface`, which seams against the canvas the page is painted with.
                colors =
                    TopAppBarDefaults.centerAlignedTopAppBarColors(
                        containerColor = MaterialTheme.colorScheme.background,
                    ),
                title = { Text(stringResource(R.string.settings_title)) },
                navigationIcon = {
                    // Brand orange marks the call to action, which on this bar is Save.
                    TextButton(
                        onClick = onCancel,
                        colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.onSurfaceVariant),
                    ) {
                        Text(stringResource(android.R.string.cancel))
                    }
                },
                actions = {
                    TextButton(
                        onClick = { if (warnBeforeSaving) showSaveWarning = true else onSave() },
                        enabled = isSaveEnabled,
                    ) {
                        Text(stringResource(R.string.save))
                    }
                },
            )
        },
        bottomBar = {
            // The tabs jump without smooth scrolling, so that crossing the bar does not drag
            // every page in between across the screen.
            NavigationBar(containerColor = MaterialTheme.colorScheme.background) {
                pages.forEachIndexed { index, page ->
                    SettingsTab(
                        selected = pagerState.currentPage == index,
                        labelRes = page.labelRes,
                        iconRes = page.iconRes,
                        onClick = { scope.launch { pagerState.scrollToPage(index) } },
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
                        managedStatus = managedStatus,
                        onAccountSlugChange = onAccountSlugChange,
                        onStartOnLoginChange = onStartOnLoginChange,
                        onConnectOnStartChange = onConnectOnStartChange,
                    )
                }

                SettingsPage.ADVANCED -> {
                    AdvancedSettingsPage(
                        config = config,
                        managedStatus = managedStatus,
                        onAuthUrlChange = onAuthUrlChange,
                        onApiUrlChange = onApiUrlChange,
                        onLogFilterChange = onLogFilterChange,
                        onResetToDefaults = onResetToDefaults,
                        buildSha = buildSha,
                    )
                }

                SettingsPage.DEVICE_TRUST -> {
                    DeviceTrustSettingsScreen(
                        state = deviceTrustState,
                        onSelectCertificate = onSelectCertificate,
                        onForgetCertificate = onForgetCertificate,
                    )
                }

                SettingsPage.LOGS -> {
                    LogSettingsPage(
                        logSizeBytes = logSizeBytes,
                        onClearLogs = onClearLogs,
                        onExportLogs = onExportLogs,
                    )
                }
            }
        }
    }

    if (showSaveWarning) {
        AlertDialog(
            onDismissRequest = { showSaveWarning = false },
            title = { Text(stringResource(R.string.settings_save_warning_title)) },
            text = { Text(stringResource(R.string.settings_save_warning_message)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        showSaveWarning = false
                        onSave()
                    },
                ) {
                    Text(stringResource(R.string.settings_save_warning_confirm))
                }
            },
        )
    }
}

@Composable
private fun RowScope.SettingsTab(
    selected: Boolean,
    labelRes: Int,
    iconRes: Int,
    onClick: () -> Unit,
) {
    NavigationBarItem(
        selected = selected,
        onClick = onClick,
        icon = { Icon(painter = painterResource(iconRes), contentDescription = null) },
        label = { Text(stringResource(labelRes)) },
    )
}
