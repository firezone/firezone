// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui

import android.app.Application
import androidx.compose.runtime.Composable
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import com.github.takahirom.roborazzi.ExperimentalRoborazziApi
import com.github.takahirom.roborazzi.captureScreenRoboImage
import com.github.takahirom.roborazzi.roborazziSystemPropertyOutputDirectory
import dev.firezone.android.R
import dev.firezone.android.STORE_SCREENSHOT_QUALIFIERS
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
import uniffi.x509claims.DetailField
import dev.firezone.android.core.data.model.Config as FirezoneConfig

// Renders the settings screens to PNGs; `./gradlew recordRoborazziDebug` writes them.
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(
    sdk = [34],
    application = Application::class,
    qualifiers = STORE_SCREENSHOT_QUALIFIERS,
)
class SettingsScreenshotTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun generalSettings() = captureSettingsPage("settings-general", R.string.general_settings_title)

    @Test
    fun advancedSettings() = captureSettingsPage("settings-advanced", R.string.advanced_settings_title)

    @Test
    fun deviceTrustSettingsWithCertificate() = captureDeviceTrustPage("device-trust-filled", availableCertificate)

    @Test
    fun deviceTrustSettingsRequiringSelection() = captureDeviceTrustPage("device-trust-selection-required", selectionRequiredCertificate)

    @Test
    fun deviceTrustSettingsWithExpiredCertificate() = captureDeviceTrustPage("device-trust-expired", expiredCertificate)

    @Test
    fun logSettings() = captureSettingsPage("settings-logs", R.string.log_settings_title)

    private fun captureDeviceTrustPage(
        name: String,
        state: DeviceTrustSettingsViewModel.UiState,
    ) = captureSettingsPage(name, R.string.device_trust_settings_title, state)

    @OptIn(ExperimentalRoborazziApi::class)
    private fun captureSettingsPage(
        name: String,
        tabLabel: Int,
        deviceTrustState: DeviceTrustSettingsViewModel.UiState = DeviceTrustSettingsViewModel.UiState(),
    ) {
        composeRule.setContent { FirezoneTheme { SettingsScreenSample(deviceTrustState) } }
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

// The alias the certificate below is filed under in the system KeyChain.
private const val CERTIFICATE_ALIAS = "firezone-device"

// A certificate the KeyChain released and whose every field holds a value.
private val availableCertificate =
    DeviceTrustSettingsViewModel.UiState(
        alias = CERTIFICATE_ALIAS,
        details = certificateDetails(),
    )

// An alias the KeyChain holds a certificate for but has not released to Firezone, which leaves
// the app with nothing to present and nothing to read.
private val selectionRequiredCertificate =
    DeviceTrustSettingsViewModel.UiState(
        alias = CERTIFICATE_ALIAS,
        needsSelection = true,
    )

// A certificate whose validity window has passed. Only the portal decides whether that matters,
// so the screen shows the date and says nothing about it.
private val expiredCertificate =
    DeviceTrustSettingsViewModel.UiState(
        alias = CERTIFICATE_ALIAS,
        details =
            certificateDetails(
                notBefore = row("Not Before", "Jan  5 09:00:00 2024 +00:00"),
                notAfter = row("Not After", "Jan  5 09:00:00 2025 +00:00"),
            ),
    )

// One certificate as the Rust parser describes it, in the order the screen lists its rows.
// Every value is pinned, so a capture only moves when the screen does.
private fun certificateDetails(
    notBefore: DetailField = row("Not Before", "Jan  5 09:00:00 2026 +00:00"),
    notAfter: DetailField = row("Not After", "Jan  5 09:00:00 2027 +00:00"),
): List<DetailField> =
    listOf(
        row("Common Name", "firezone-device"),
        row("Subject", "CN=firezone-device, O=Example Corp"),
        row("Issuer", "CN=Example Corp Device CA, O=Example Corp"),
        row("MDM Device ID", "9b4d1c07-6e2a-4f83-8c15-7ad0e39b2c64"),
        row("Device Serial", "C02XK1ZGJGH5"),
        row("Serial Number", "4a:1f:8c:52:0d:9b:36:e7:11:c4:58:a3:7f:20:6b:d9"),
        notBefore,
        notAfter,
        row("Signing Algorithm", "SHA256withECDSA"),
        row(
            "SHA-256 Fingerprint",
            "3B:1D:0C:7E:59:A4:F2:68:8D:31:C0:5B:7A:96:E4:2F:" +
                "10:D8:63:4C:B5:27:9E:0A:F1:6D:82:34:C7:5E:19:AB",
        ),
    )

// A row as the parser hands it over.
private fun row(
    label: String,
    value: String?,
): DetailField = DetailField(label, value, null)

@Composable
private fun SettingsScreenSample(deviceTrustState: DeviceTrustSettingsViewModel.UiState) {
    SettingsScreen(
        config = sampleConfig,
        managedStatus = nothingManaged,
        isSaveEnabled = true,
        logSizeBytes = LOG_DIRECTORY_BYTES,
        deviceTrustState = deviceTrustState,
        showDeviceTrust = deviceTrustState.alias != null,
        warnBeforeSaving = false,
        onAuthUrlChange = {},
        onApiUrlChange = {},
        onLogFilterChange = {},
        onAccountSlugChange = {},
        onStartOnLoginChange = {},
        onConnectOnStartChange = {},
        onResetToDefaults = {},
        onClearLogs = {},
        onExportLogs = {},
        onLogsShown = {},
        onSelectCertificate = {},
        onDeviceTrustShown = {},
        onSave = {},
        onCancel = {},
        // The advanced page shows the commit the app was built from, which changes with every
        // push; pin it so the image only changes when the UI does.
        buildSha = "Build: \"00000000\"",
    )
}
