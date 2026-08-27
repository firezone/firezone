// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui

import android.app.Application
import androidx.compose.runtime.Composable
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import com.github.takahirom.roborazzi.ExperimentalRoborazziApi
import com.github.takahirom.roborazzi.RobolectricDeviceQualifiers
import com.github.takahirom.roborazzi.captureScreenRoboImage
import com.github.takahirom.roborazzi.roborazziSystemPropertyOutputDirectory
import dev.firezone.android.R
import dev.firezone.android.core.data.model.ManagedConfigStatus
import dev.firezone.android.features.settings.ui.compose.SettingsScreen
import dev.firezone.android.ui.theme.FirezoneTheme
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import dev.firezone.android.core.data.model.Config as FirezoneConfig

// Renders the settings screens to PNGs; `./gradlew recordRoborazziDebug` writes them.
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(
    sdk = [34],
    application = Application::class,
    qualifiers = RobolectricDeviceQualifiers.Pixel5,
)
class SettingsScreenshotTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun generalSettings() = captureSettingsPage("settings-general", R.string.general_settings_title)

    @Test
    fun advancedSettings() = captureSettingsPage("settings-advanced", R.string.advanced_settings_title)

    @Test
    fun logSettings() = captureSettingsPage("settings-logs", R.string.log_settings_title)

    @OptIn(ExperimentalRoborazziApi::class)
    private fun captureSettingsPage(
        name: String,
        tabLabel: Int,
    ) {
        composeRule.setContent { FirezoneTheme { SettingsScreenSample() } }
        composeRule.onNodeWithText(RuntimeEnvironment.getApplication().getString(tabLabel)).performClick()
        composeRule.waitForIdle()

        captureScreenRoboImage("${roborazziSystemPropertyOutputDirectory()}/$name.png")
    }
}

// Renders as "3.4 MB", mirroring the desktop client's screenshot fixture.
private const val LOG_DIRECTORY_BYTES = 3_400_000L

// What a signed-in user of a production account sees.
private val sampleConfig =
    FirezoneConfig(
        authUrl = "https://app.firezone.dev",
        apiUrl = "wss://api.firezone.dev",
        logFilter = "info",
        accountSlug = "example-corp",
        startOnLogin = true,
        connectOnStart = false,
    )

private val nothingManaged =
    ManagedConfigStatus(
        isAuthUrlManaged = false,
        isApiUrlManaged = false,
        isLogFilterManaged = false,
        isAccountSlugManaged = false,
        isStartOnLoginManaged = false,
        isConnectOnStartManaged = false,
    )

@Composable
private fun SettingsScreenSample() {
    SettingsScreen(
        config = sampleConfig,
        managedStatus = nothingManaged,
        isSaveEnabled = true,
        logSizeBytes = LOG_DIRECTORY_BYTES,
        warnBeforeSaving = false,
        onConfigChange = {},
        onResetToDefaults = {},
        onClearLogs = {},
        onExportLogs = {},
        onLogsShown = {},
        onSave = {},
        onCancel = {},
        // The advanced page shows the commit the app was built from, which changes with every
        // push; pin it so the image only changes when the UI does.
        buildSha = "Build: \"00000000\"",
    )
}
