// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui

import android.app.Application
import android.os.Bundle
import android.os.Looper
import android.widget.TextView
import androidx.activity.viewModels
import androidx.appcompat.app.AppCompatActivity
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
import java.io.File
import java.io.RandomAccessFile
import dev.firezone.android.core.data.model.Config as FirezoneConfig

// Renders the settings screens to PNGs so their states can be reviewed without an emulator.
// `./gradlew recordRoborazziDebug` writes them; a plain unit-test run captures nothing.
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
    fun logSettings() = captureSettingsPage("settings-logs", R.id.settingsLogs)

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

    // The directory size is computed on the IO dispatcher, so wait for it to land in the
    // UI state (and for the main looper to render it) before photographing.
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

// What a signed-in user of a production account sees; also mirrors the desktop client's
// screenshot fixtures.
private val sampleConfig =
    FirezoneConfig(
        authUrl = "https://app.firezone.dev",
        apiUrl = "wss://api.firezone.dev",
        logFilter = "info",
        accountSlug = "acme-corp",
        startOnLogin = true,
        connectOnStart = false,
    )

// Hosts the settings pages the way `SettingsActivity` does: the same layout, fragments, and
// view model, with the pager and the save button wired the same way. Only the Hilt graph is
// replaced, by building the view model by hand from preferences seeded with `sampleConfig`.
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

                override fun createFragment(position: Int): Fragment = settingsPages[position].second()
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
