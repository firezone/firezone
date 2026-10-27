// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui.compose

import android.app.Application
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextReplacement
import dev.firezone.android.core.data.model.Config
import dev.firezone.android.core.data.model.ManagedConfigStatus
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
@org.robolectric.annotation.Config(sdk = [34], application = Application::class)
class LogSettingsPageTest {
    @get:Rule
    val composeRule = createComposeRule()

    private var clears = 0
    private var savedLogFilter: String? = null

    private fun showPage() {
        composeRule.setContent {
            LogSettingsPage(
                config = Config("", "", "info", "", startOnLogin = false, connectOnStart = false),
                managedStatus = ManagedConfigStatus.NOTHING_MANAGED,
                logSizeBytes = 1024,
                onLogFilterChange = { savedLogFilter = it },
                onClearLogs = { clears++ },
                onExportLogs = {},
                versionName = "1.0.0",
                buildSha = "unknown",
                validateLogFilter = { if (it == "info,foo=bar=baz") "invalid directive" else null },
            )
        }
    }

    @Test
    fun `clearing the logs asks first and only clears on confirm`() {
        showPage()

        composeRule.onNodeWithContentDescription("Clear Log Directory").performClick()
        composeRule.onNodeWithText("Clear log files?").assertIsDisplayed()
        composeRule.onNodeWithText("Cancel").performClick()
        assertEquals(0, clears)

        composeRule.onNodeWithContentDescription("Clear Log Directory").performClick()
        composeRule.onNodeWithText("Clear").performClick()
        assertEquals(1, clears)
    }

    @Test
    fun `a log filter connlib rejects cannot be saved`() {
        showPage()

        composeRule.onNodeWithText("Log Filter").performClick()
        composeRule.onNode(hasSetTextAction()).performTextReplacement("info,foo=bar=baz")
        composeRule.onNodeWithText("Invalid log filter: invalid directive").assertIsDisplayed()
        composeRule.onNodeWithText("OK").assertIsNotEnabled()

        composeRule.onNode(hasSetTextAction()).performTextReplacement("debug")
        composeRule.onNodeWithText("OK").assertIsEnabled().performClick()
        assertEquals("debug", savedLogFilter)

        composeRule.onNodeWithText("Log Filter").performClick()
        composeRule.onNode(hasSetTextAction()).performTextReplacement("")
        composeRule.onNodeWithText("OK").assertIsEnabled().performClick()
        assertEquals("", savedLogFilter)
    }
}
