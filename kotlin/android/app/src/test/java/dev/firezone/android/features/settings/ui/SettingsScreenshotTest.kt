// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui

import android.app.Application
import androidx.compose.runtime.Composable
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
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
import uniffi.x509claims.DetailField
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
    fun deviceTrustSettingsWithCertificate() = captureDeviceTrustPage("device-trust-filled", availableCertificate)

    @Test
    fun deviceTrustSettingsRequiringSelection() = captureDeviceTrustPage("device-trust-selection-required", selectionRequiredCertificate)

    @Test
    fun deviceTrustSettingsWithExpiredCertificate() = captureDeviceTrustPage("device-trust-expired", expiredCertificate)

    // The buttons follow the rows, so only the end of the scroll shows what an administrator's
    // certificate takes away: the same certificate, picked by the user, still offers Forget.
    @Test
    fun deviceTrustSettingsWithManagedCertificate() =
        captureDeviceTrustPage("device-trust-managed-scrolled", managedCertificate, scrollToEnd = true)

    @Test
    fun deviceTrustSettingsWithUnmanagedCertificate() =
        captureDeviceTrustPage("device-trust-unmanaged-scrolled", availableCertificate, scrollToEnd = true)

    @Test
    fun logSettings() = captureSettingsPage("settings-logs", R.string.log_settings_title)

    private fun captureDeviceTrustPage(
        name: String,
        state: DeviceTrustSettingsViewModel.UiState,
        scrollToEnd: Boolean = false,
    ) = captureSettingsPage(name, R.string.device_trust_settings_title, state, scrollToEnd)

    @OptIn(ExperimentalRoborazziApi::class)
    private fun captureSettingsPage(
        name: String,
        tabLabel: Int,
        deviceTrustState: DeviceTrustSettingsViewModel.UiState = DeviceTrustSettingsViewModel.UiState(),
        scrollToEnd: Boolean = false,
    ) {
        composeRule.setContent { FirezoneTheme { SettingsScreenSample(deviceTrustState) } }
        composeRule.onNodeWithText(RuntimeEnvironment.getApplication().getString(tabLabel)).performClick()
        composeRule.waitForIdle()

        if (scrollToEnd) {
            scrollToEnd()
        }

        captureScreenRoboImage("${roborazziSystemPropertyOutputDirectory()}/$name.png")
    }

    // The pager scrolls sideways, so the page under it is the only node with a vertical range to
    // read the distance left to travel off.
    private fun scrollToEnd() {
        val page = composeRule.onNode(SemanticsMatcher.keyIsDefined(SemanticsProperties.VerticalScrollAxisRange))
        val range = page.fetchSemanticsNode().config[SemanticsProperties.VerticalScrollAxisRange]

        page.performSemanticsAction(SemanticsActions.ScrollBy) { it(0f, range.maxValue() - range.value()) }
        composeRule.waitForIdle()
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

// The same certificate, handed down by an administrator and released by the KeyChain, which
// leaves the user nothing to pick or clear.
private val managedCertificate = availableCertificate.copy(isManaged = true)

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
        hasConfiguredCertificateAlias = deviceTrustState.alias != null,
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
        onForgetCertificate = {},
        onDeviceTrustShown = {},
        onSave = {},
        onCancel = {},
        // The advanced page shows the commit the app was built from, which changes with every
        // push; pin it so the image only changes when the UI does.
        buildSha = "Build: \"00000000\"",
    )
}
