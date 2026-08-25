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
import dev.firezone.android.core.data.Repository
import dev.firezone.android.databinding.ActivitySettingsBinding
import dev.firezone.android.features.session.ui.compose.FirezoneTheme
import dev.firezone.android.features.settings.ui.compose.X509SettingsScreen
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import uniffi.x509claims.ClaimValue
import uniffi.x509claims.DetailField
import uniffi.x509claims.RejectionReason
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
    @Test
    fun generalSettings() = captureSettingsPage("settings-general", R.id.settingsGeneral)

    @Test
    fun advancedSettings() = captureSettingsPage("settings-advanced", R.id.settingsAdvanced)

    @Test
    fun x509SettingsWithCertificate() = captureX509Page("x509-filled", usableCertificate)

    @Test
    fun x509SettingsWithoutCertificate() = captureX509Page("x509-empty", noCertificate)

    @Test
    fun x509SettingsWithRejectedClaim() = captureX509Page("x509-rejected-claim", certificateWithRejectedClaim)

    @Test
    fun x509SettingsWithUnusableCertificate() = captureX509Page("x509-unusable", unusableCertificate)

    @Test
    fun logSettings() = captureSettingsPage("settings-logs", R.id.settingsLogs)

    private fun captureX509Page(
        name: String,
        state: X509SettingsViewModel.UiState,
    ) {
        x509ScreenshotState = state

        captureSettingsPage(name, R.id.settingsX509)
    }

    @OptIn(ExperimentalRoborazziApi::class)
    private fun captureSettingsPage(
        name: String,
        navigationItemId: Int,
    ) {
        seedLogDirectory()

        val activity = Robolectric.buildActivity(SettingsScreenshotActivity::class.java).setup().get()
        activity.showPage(settingsPages.indexOfFirst { it.first == navigationItemId })
        shadowOf(Looper.getMainLooper()).idle()

        // The advanced page shows the commit the app was built from, which changes with
        // every push; pin it so the image only changes when the UI does.
        activity.findViewById<TextView>(R.id.tvGitSha)?.text = "Build: \"00000000\""
        shadowOf(Looper.getMainLooper()).idle()

        if (navigationItemId == R.id.settingsLogs) {
            awaitLogDirectorySize(activity)
        }

        activity.window.decorView.captureRoboImage("${roborazziSystemPropertyOutputDirectory()}/$name.png")
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

// The state `X509ScreenshotFragment` renders, set before the activity reaches the X.509 page.
private var x509ScreenshotState = X509SettingsViewModel.UiState()

// A certificate the KeyChain released and whose every claim the parser attested.
private val usableCertificate =
    X509SettingsViewModel.UiState(
        alias = CERTIFICATE_ALIAS,
        isUsable = true,
        details =
            certificateDetails(
                actorEmail = ClaimValue.Present("alice@example.com"),
                unattestedNames = emptyList(),
            ),
    )

// No administrator handed a certificate down and the user picked none.
private val noCertificate = X509SettingsViewModel.UiState()

// The same certificate, spelling the actor's email in a way the parser will not attest. Claims
// have no say in whether a certificate can be presented, so Firezone still signs in with it.
private val certificateWithRejectedClaim =
    X509SettingsViewModel.UiState(
        alias = CERTIFICATE_ALIAS,
        isUsable = true,
        details =
            certificateDetails(
                actorEmail = ClaimValue.Invalid(RejectionReason.NOT_AN_EMAIL_ADDRESS),
                unattestedNames = listOf("URI: firezone://email/alice.example.com"),
            ),
    )

// An alias the KeyChain holds a certificate for but has not released to Firezone, which leaves
// the app with nothing to present and nothing to read.
private val unusableCertificate =
    X509SettingsViewModel.UiState(
        alias = CERTIFICATE_ALIAS,
        isUsable = false,
    )

// One certificate as the KeyChain and the Rust parser describe it, in the order the screen lists
// their rows. Every value is pinned, so a capture only moves when the screen does.
private fun certificateDetails(
    actorEmail: ClaimValue,
    unattestedNames: List<String>,
): List<DetailField> =
    buildList {
        add(DetailField("KeyChain Alias", ClaimValue.Present(CERTIFICATE_ALIAS)))
        add(DetailField("Certificates In Chain", ClaimValue.Present("2")))
        add(DetailField("Common Name", ClaimValue.Present("alice@example.com")))
        add(DetailField("Subject", ClaimValue.Present("CN=alice@example.com, O=Example Corp")))
        add(DetailField("Issuer", ClaimValue.Present("CN=Example Corp Device CA, O=Example Corp")))
        add(DetailField("Actor Email", actorEmail))
        add(DetailField("Account ID", ClaimValue.Present("5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3")))
        add(DetailField("MDM Device ID", ClaimValue.Present("9b4d1c07-6e2a-4f83-8c15-7ad0e39b2c64")))
        add(DetailField("Device Serial", ClaimValue.Present("C02XK1ZGJGH5")))

        // The parser lists the alternative names no claim row shows, which is where a name it
        // refused to attest ends up.
        if (unattestedNames.isNotEmpty()) {
            add(
                DetailField(
                    "Subject Alternative Names",
                    ClaimValue.Present(unattestedNames.joinToString("\n")),
                ),
            )
        }

        add(DetailField("Serial Number", ClaimValue.Present("4a:1f:8c:52:0d:9b:36:e7:11:c4:58:a3:7f:20:6b:d9")))
        add(DetailField("Not Before", ClaimValue.Present("Jan  5 09:00:00 2026 +00:00")))
        add(DetailField("Not After", ClaimValue.Present("Jan  5 09:00:00 2027 +00:00")))
        add(DetailField("Signing Algorithm", ClaimValue.Present("SHA256withECDSA")))
        add(
            DetailField(
                "SHA-256 Fingerprint",
                ClaimValue.Present(
                    "3B:1D:0C:7E:59:A4:F2:68:8D:31:C0:5B:7A:96:E4:2F:" +
                        "10:D8:63:4C:B5:27:9E:0A:F1:6D:82:34:C7:5E:19:AB",
                ),
            ),
        )
    }

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
                SettingsViewModel(repository)
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        setTheme(R.style.AppTheme_Base)
        super.onCreate(savedInstanceState)
        binding = ActivitySettingsBinding.inflate(layoutInflater)
        setContentView(binding.root)

        binding.viewPager.adapter =
            object : FragmentStateAdapter(this) {
                override fun getItemCount(): Int = settingsPages.size

                override fun createFragment(position: Int): Fragment =
                    when (settingsPages[position].first) {
                        R.id.settingsX509 -> X509ScreenshotFragment()
                        else -> settingsPages[position].second()
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
            .findItem(settingsPages[position].first)
            .isChecked = true
    }
}

// Shows the X.509 page the way `X509SettingsFragment` does, on a fixture rather than on a Hilt
// graph and the system KeyChain, so each state of the screen can be photographed on its own.
internal class X509ScreenshotFragment : Fragment() {
    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?,
    ): View =
        ComposeView(requireContext()).apply {
            setViewCompositionStrategy(ViewCompositionStrategy.DisposeOnViewTreeLifecycleDestroyed)
            setContent {
                FirezoneTheme {
                    X509SettingsScreen(
                        state = x509ScreenshotState,
                        onSelectCertificate = {},
                        onForgetCertificate = {},
                    )
                }
            }
        }
}
