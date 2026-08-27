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
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import dev.firezone.android.R
import dev.firezone.android.core.data.model.Config
import dev.firezone.android.core.data.model.ManagedConfigStatus
import kotlinx.coroutines.launch

private const val PAGE_GENERAL = 0
private const val PAGE_ADVANCED = 1
private const val PAGE_LOGS = 2
private const val PAGE_COUNT = 3

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    config: Config,
    managedStatus: ManagedConfigStatus?,
    isSaveEnabled: Boolean,
    logSizeBytes: Long,
    warnBeforeSaving: Boolean,
    onConfigChange: (Config) -> Unit,
    onResetToDefaults: () -> Unit,
    onClearLogs: () -> Unit,
    onExportLogs: () -> Unit,
    onLogsShown: () -> Unit,
    onSave: () -> Unit,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
    buildSha: String = stringResource(R.string.git_sha),
) {
    val pagerState = rememberPagerState(pageCount = { PAGE_COUNT })
    val scope = rememberCoroutineScope()
    var showSaveWarning by rememberSaveable { mutableStateOf(false) }

    // The log directory grows while the app runs, so re-measure it each time the page is shown.
    LaunchedEffect(pagerState.currentPage) {
        if (pagerState.currentPage == PAGE_LOGS) onLogsShown()
    }

    Scaffold(
        modifier = modifier,
        topBar = {
            CenterAlignedTopAppBar(
                title = { Text(stringResource(R.string.settings_title)) },
                navigationIcon = {
                    // M3 labels text buttons with `primary`, which the brand makes orange.
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
                        colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.onSurfaceVariant),
                    ) {
                        Text(stringResource(R.string.save))
                    }
                },
            )
        },
        bottomBar = {
            // The tabs jump without smooth scrolling, so that crossing the bar does not drag
            // every page in between across the screen.
            NavigationBar {
                SettingsTab(
                    selected = pagerState.currentPage == PAGE_GENERAL,
                    labelRes = R.string.general_settings_title,
                    iconRes = R.drawable.rounded_discover_tune_black_24dp,
                    onClick = { scope.launch { pagerState.scrollToPage(PAGE_GENERAL) } },
                )
                SettingsTab(
                    selected = pagerState.currentPage == PAGE_ADVANCED,
                    labelRes = R.string.advanced_settings_title,
                    iconRes = R.drawable.rounded_settings_black_24dp,
                    onClick = { scope.launch { pagerState.scrollToPage(PAGE_ADVANCED) } },
                )
                SettingsTab(
                    selected = pagerState.currentPage == PAGE_LOGS,
                    labelRes = R.string.log_settings_title,
                    iconRes = R.drawable.rounded_description_black_24dp,
                    onClick = { scope.launch { pagerState.scrollToPage(PAGE_LOGS) } },
                )
            }
        },
    ) { innerPadding ->
        HorizontalPager(state = pagerState, modifier = Modifier.fillMaxSize().padding(innerPadding)) { page ->
            when (page) {
                PAGE_GENERAL -> {
                    GeneralSettingsPage(
                        config = config,
                        managedStatus = managedStatus,
                        onConfigChange = onConfigChange,
                    )
                }

                PAGE_ADVANCED -> {
                    AdvancedSettingsPage(
                        config = config,
                        managedStatus = managedStatus,
                        onConfigChange = onConfigChange,
                        onResetToDefaults = onResetToDefaults,
                        buildSha = buildSha,
                    )
                }

                PAGE_LOGS -> {
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
                    colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.onSurfaceVariant),
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
