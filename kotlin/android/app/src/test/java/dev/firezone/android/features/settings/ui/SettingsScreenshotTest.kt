// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui

import android.app.Application
import android.os.Bundle
import android.os.Looper
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.activity.viewModels
import androidx.appcompat.app.AppCompatActivity
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.ViewCompositionStrategy
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.hasScrollAction
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.performSemanticsAction
import androidx.fragment.app.Fragment
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import androidx.viewpager2.adapter.FragmentStateAdapter
import com.github.takahirom.roborazzi.ExperimentalRoborazziApi
import com.github.takahirom.roborazzi.RobolectricDeviceQualifiers
import com.github.takahirom.roborazzi.captureRoboImage
import com.github.takahirom.roborazzi.roborazziSystemPropertyOutputDirectory
import dev.firezone.android.R
import dev.firezone.android.core.data.ManagedConfigurationReader
import dev.firezone.android.core.data.ManagedConfigurationSource
import dev.firezone.android.core.data.Repository
import dev.firezone.android.databinding.ActivitySettingsBinding
import dev.firezone.android.features.session.ui.compose.FirezoneTheme
import dev.firezone.android.features.settings.ui.compose.DeviceTrustSettingsScreen
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import uniffi.x509claims.DetailField
import java.io.File
import java.io.RandomAccessFile
import dev.firezone.android.core.data.model.Config as FirezoneConfig

// Renders the settings screens to PNGs; `./gradlew recordRoborazziDebug` writes them.
//
// `SettingsActivity` only works on top of a Hilt graph, which a screenshot does not need,
// so `SettingsScreenshotActivity` below hosts the real layout and fragments instead.
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(
    sdk = [34],
    application = Application::class,
    qualifiers = RobolectricDeviceQualifiers.Pixel5,
)
class SettingsScreenshotTest {
    // Reaches into the Compose content the fragments host, which the scrolled Device Trust
    // captures have to drive. The rule hosts nothing itself; the activity below is still
    // Robolectric's to build.
    @get:Rule
    val composeRule = createEmptyComposeRule()

    @Test
    fun generalSettings() = captureSettingsPage("settings-general", R.id.settingsGeneral)

    @Test
    fun advancedSettings() = captureSettingsPage("settings-advanced", R.id.settingsAdvanced)

    @Test
    fun deviceTrustSettingsWithCertificate() = captureDeviceTrustPage("device-trust-filled", availableCertificate)

    @Test
    fun deviceTrustSettingsRequiringSelection() = captureDeviceTrustPage("device-trust-selection-required", selectionRequiredCertificate)

    @Test
    fun deviceTrustSettingsWithExpiredCertificate() = captureDeviceTrustPage("device-trust-expired", expiredCertificate)

    // The buttons follow the rows, so only the end of the scroll shows what an administrator's
    // certificate takes away: the same certificate, picked by the user, still offers Forget.
    @Test
    fun deviceTrustSettingsWithManagedCertificate() = captureDeviceTrustPageEnd("device-trust-managed-scrolled", managedCertificate)

    @Test
    fun deviceTrustSettingsWithUnmanagedCertificate() = captureDeviceTrustPageEnd("device-trust-unmanaged-scrolled", availableCertificate)

    @Test
    fun logSettings() = captureSettingsPage("settings-logs", R.id.settingsLogs)

    private fun captureDeviceTrustPage(
        name: String,
        state: DeviceTrustSettingsViewModel.UiState,
    ) {
        deviceTrustScreenshotState = state

        captureSettingsPage(name, R.id.settingsDeviceTrust, hasConfiguredCertificateAlias = true)
    }

    private fun captureDeviceTrustPageEnd(
        name: String,
        state: DeviceTrustSettingsViewModel.UiState,
    ) {
        deviceTrustScreenshotState = state

        captureSettingsPage(
            name,
            R.id.settingsDeviceTrust,
            scrollToEnd = true,
            hasConfiguredCertificateAlias = true,
        )
    }

    @OptIn(ExperimentalRoborazziApi::class)
    private fun captureSettingsPage(
        name: String,
        navigationItemId: Int,
        scrollToEnd: Boolean = false,
        hasConfiguredCertificateAlias: Boolean = false,
    ) {
        seedLogDirectory()
        settingsScreenshotPages = settingsPages(hasConfiguredCertificateAlias)

        val activity = Robolectric.buildActivity(SettingsScreenshotActivity::class.java).setup().get()
        activity.showPage(settingsScreenshotPages.indexOfFirst { it.first == navigationItemId })
        shadowOf(Looper.getMainLooper()).idle()

        // The advanced page shows the commit the app was built from, which changes with
        // every push; pin it so the image only changes when the UI does.
        activity.findViewById<TextView>(R.id.tvGitSha)?.text = "Build: \"00000000\""
        shadowOf(Looper.getMainLooper()).idle()

        if (navigationItemId == R.id.settingsLogs) {
            awaitLogDirectorySize(activity)
        }

        if (scrollToEnd) {
            scrollToEnd()
        }

        activity.window.decorView.captureRoboImage("${roborazziSystemPropertyOutputDirectory()}/$name.png")
    }

    // `SessionScreen` scrolls a list, which can be driven to a row number; this screen is a plain
    // scrolling `Column`, so the distance left to travel is read off the semantics tree instead.
    private fun scrollToEnd() {
        val rows = composeRule.onNode(hasScrollAction())
        val range = rows.fetchSemanticsNode().config[SemanticsProperties.VerticalScrollAxisRange]

        rows.performSemanticsAction(SemanticsActions.ScrollBy) { it(0f, range.maxValue() - range.value()) }
        composeRule.waitForIdle()
    }

    // The logs page shows the size of the log directory, so give it one log file to measure.
    private fun seedLogDirectory() {
        val logFile = File(RuntimeEnvironment.getApplication().cacheDir, "logs/connlib.log")
        logFile.parentFile?.mkdirs()
        RandomAccessFile(logFile, "rw").use { it.setLength(LOG_DIRECTORY_BYTES) }
    }

    // The directory size is computed on the IO dispatcher, so wait for it to reach the UI.
    private fun awaitLogDirectorySize(activity: SettingsScreenshotActivity) {
        val deadline = System.currentTimeMillis() + 10_000
        while (activity.viewModel.uiState.value.logSizeBytes != LOG_DIRECTORY_BYTES) {
            check(System.currentTimeMillis() < deadline) { "Log directory size was never computed" }
            Thread.sleep(10)
        }
        shadowOf(Looper.getMainLooper()).idle()
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

// The alias the certificate below is filed under in the system KeyChain.
private const val CERTIFICATE_ALIAS = "firezone-device"

// The state `DeviceTrustScreenshotFragment` renders, set before the activity reaches Device Trust.
private var deviceTrustScreenshotState = DeviceTrustSettingsViewModel.UiState()
private var settingsScreenshotPages = settingsPages(hasConfiguredCertificateAlias = false)

// A certificate the KeyChain released and whose every claim holds a value.
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
    buildList {
        add(row("Common Name", "firezone-device"))
        add(row("Subject", "CN=firezone-device, O=Example Corp"))
        add(row("Issuer", "CN=Example Corp Device CA, O=Example Corp"))
        add(row("MDM Device ID", "9b4d1c07-6e2a-4f83-8c15-7ad0e39b2c64"))
        add(row("Device Serial", "C02XK1ZGJGH5"))
        add(row("Serial Number", "4a:1f:8c:52:0d:9b:36:e7:11:c4:58:a3:7f:20:6b:d9"))
        add(notBefore)
        add(notAfter)
        add(row("Signing Algorithm", "SHA256withECDSA"))
        add(
            row(
                "SHA-256 Fingerprint",
                "3B:1D:0C:7E:59:A4:F2:68:8D:31:C0:5B:7A:96:E4:2F:" +
                    "10:D8:63:4C:B5:27:9E:0A:F1:6D:82:34:C7:5E:19:AB",
            ),
        )
    }

// A row as the parser hands it over.
private fun row(
    label: String,
    value: String?,
): DetailField = DetailField(label, value, null)

// Hosts the settings pages the way `SettingsActivity` does, with the Hilt graph replaced by
// a view model built by hand from preferences seeded with `sampleConfig`.
internal class SettingsScreenshotActivity : AppCompatActivity() {
    private lateinit var binding: ActivitySettingsBinding

    val viewModel: SettingsViewModel by viewModels()

    override val defaultViewModelProviderFactory: ViewModelProvider.Factory =
        viewModelFactory {
            initializer {
                val repository =
                    Repository(
                        applicationContext,
                        Dispatchers.Unconfined,
                        getSharedPreferences("settings-screenshot", MODE_PRIVATE),
                    )
                runBlocking { repository.saveSettings(sampleConfig).first() }
                val managedConfigurationSource =
                    ManagedConfigurationSource(
                        applicationContext,
                        ManagedConfigurationReader { Bundle() },
                        repository,
                        CoroutineScope(SupervisorJob() + Dispatchers.Unconfined),
                    )
                SettingsViewModel(repository, managedConfigurationSource)
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        setTheme(R.style.AppTheme_Base)
        super.onCreate(savedInstanceState)
        binding = ActivitySettingsBinding.inflate(layoutInflater)
        setContentView(binding.root)

        binding.bottomNavigation.menu
            .findItem(R.id.settingsDeviceTrust)
            .isVisible = settingsScreenshotPages.any { it.first == R.id.settingsDeviceTrust }
        binding.viewPager.adapter =
            object : FragmentStateAdapter(this) {
                override fun getItemCount(): Int = settingsScreenshotPages.size

                override fun createFragment(position: Int): Fragment =
                    when (settingsScreenshotPages[position].first) {
                        R.id.settingsDeviceTrust -> DeviceTrustScreenshotFragment()
                        else -> settingsScreenshotPages[position].second()
                    }
            }

        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                viewModel.uiState.collect { uiState ->
                    binding.btSaveSettings.isEnabled = uiState.isSaveButtonEnabled
                }
            }
        }

        viewModel.populateFieldsFromConfig()
    }

    fun showPage(position: Int) {
        binding.viewPager.setCurrentItem(position, false)
        binding.bottomNavigation.menu
            .findItem(settingsScreenshotPages[position].first)
            .isChecked = true
    }
}

// Shows Device Trust the way `DeviceTrustSettingsFragment` does, on a fixture rather than on a
// Hilt graph and the system KeyChain, so each state of the screen can be photographed on its own.
internal class DeviceTrustScreenshotFragment : Fragment() {
    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?,
    ): View =
        ComposeView(requireContext()).apply {
            setViewCompositionStrategy(ViewCompositionStrategy.DisposeOnViewTreeLifecycleDestroyed)
            setContent {
                FirezoneTheme {
                    DeviceTrustSettingsScreen(
                        state = deviceTrustScreenshotState,
                        onSelectCertificate = {},
                        onForgetCertificate = {},
                    )
                }
            }
        }
}
