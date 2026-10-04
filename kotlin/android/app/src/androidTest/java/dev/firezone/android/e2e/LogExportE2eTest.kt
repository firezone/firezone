// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.e2e

import android.app.Activity
import android.app.Instrumentation.ActivityResult
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import android.text.format.Formatter
import androidx.core.content.IntentCompat
import androidx.test.espresso.intent.ActivityResultFunction
import androidx.test.espresso.intent.Intents.intending
import androidx.test.espresso.intent.matcher.IntentMatchers.hasAction
import androidx.test.espresso.intent.rule.IntentsRule
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import dagger.hilt.android.testing.HiltAndroidRule
import dagger.hilt.android.testing.HiltAndroidTest
import dev.firezone.android.R
import dev.firezone.android.features.settings.ui.SettingsActivity
import dev.firezone.android.tunnel.FakeSessionFactory
import dev.firezone.android.tunnel.TestRestrictions
import dev.firezone.android.tunnel.TunnelService
import dev.firezone.android.tunnel.awaitTextOnScreen
import dev.firezone.android.tunnel.clickTextOnScreen
import dev.firezone.android.tunnel.finishAllActivities
import dev.firezone.android.tunnel.resumedActivity
import dev.firezone.android.tunnel.stopTunnelService
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import java.util.regex.Pattern
import java.util.zip.ZipInputStream
import javax.inject.Inject

// The share sheet stands in for the app the user sends their logs to, so what it is handed has to
// be everything that app needs to read them.
@HiltAndroidTest
class LogExportE2eTest {
    @get:Rule(order = 0)
    val hiltRule = HiltAndroidRule(this)

    @get:Rule(order = 1)
    val intentsRule = IntentsRule()

    @Inject
    lateinit var preferences: SharedPreferences

    @Before
    fun setUp() {
        hiltRule.inject()
        FakeSessionFactory.reset()
        finishAllActivities()
        stopTunnelService()
        preferences.edit().clear().commit()
        TestRestrictions.bundle.clear()
        logDir().deleteRecursively()
    }

    @Test
    fun exportingLogsSharesAZipOfTheLogDirectory() {
        // Connlib's logger is never configured under test, so nothing else writes here.
        val log = File(logDir(), LOG_FILE).apply { writeText(LOG_LINE) }
        val chooser = stubChooser()

        context.startActivity(
            Intent(context, SettingsActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK),
        )

        clickTextOnScreen(context.getString(R.string.log_settings_title))
        // Export stays disabled until the page has measured the logs.
        awaitTextOnScreen(context.getString(R.string.log_directory_size, Formatter.formatShortFileSize(context, log.length())))
        clickButton(context.getString(R.string.share_diagnostic_logs))

        await("the share sheet") { chooser.get() != null }
        val send = checkNotNull(IntentCompat.getParcelableExtra(chooser.get(), Intent.EXTRA_INTENT, Intent::class.java))
        assertEquals(Intent.ACTION_SEND, send.action)
        assertTrue("the recipient is not let read the logs", send.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0)

        val stream = checkNotNull(IntentCompat.getParcelableExtra(send, Intent.EXTRA_STREAM, Uri::class.java))
        assertEquals("application/zip", context.contentResolver.getType(stream))
        assertEquals(mapOf(LOG_FILE to LOG_LINE), zipEntries(stream))
    }

    private fun stubChooser(): AtomicReference<Intent> {
        val captured = AtomicReference<Intent>()

        intending(hasAction(Intent.ACTION_CHOOSER)).respondWithFunction(
            ActivityResultFunction { intent ->
                captured.set(intent)
                ActivityResult(Activity.RESULT_CANCELED, null)
            },
        )

        return captured
    }

    // A theme can draw a button's label in capitals, which is also how it reads to accessibility.
    private fun clickButton(label: String) {
        UiDevice
            .getInstance(InstrumentationRegistry.getInstrumentation())
            .wait(Until.findObject(By.text(Pattern.compile(Pattern.quote(label), Pattern.CASE_INSENSITIVE))), TIMEOUT_MS)
            ?.click()
            ?: throw AssertionError("Timed out waiting for \"$label\" on screen, showing ${resumedActivity()}")
    }

    private fun zipEntries(uri: Uri): Map<String, String> =
        ZipInputStream(checkNotNull(context.contentResolver.openInputStream(uri))).use { zip ->
            generateSequence { zip.nextEntry }
                .filterNot { it.isDirectory }
                .associate { it.name to zip.readBytes().decodeToString() }
        }

    private fun logDir() = File(TunnelService.logDir(context))

    private fun await(
        what: String,
        condition: () -> Boolean,
    ) {
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(TIMEOUT_MS)

        while (!condition()) {
            if (System.nanoTime() > deadline) {
                throw AssertionError("Timed out waiting for $what, showing ${resumedActivity()}")
            }

            Thread.sleep(50)
        }
    }

    private val context: Context
        get() = InstrumentationRegistry.getInstrumentation().targetContext

    private companion object {
        const val LOG_FILE = "connlib.e2e.log"
        const val LOG_LINE = "the tunnel came up\n"
        const val TIMEOUT_MS = 20_000L
    }
}
