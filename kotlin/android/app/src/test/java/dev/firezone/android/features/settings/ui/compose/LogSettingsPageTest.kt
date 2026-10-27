// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui.compose

import android.app.Application
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
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

    @Test
    fun `clearing the logs asks first and only clears on confirm`() {
        composeRule.setContent {
            LogSettingsPage(
                config = Config("", "", "info", "", startOnLogin = false, connectOnStart = false),
                managedStatus = ManagedConfigStatus.NOTHING_MANAGED,
                logSizeBytes = 1024,
                onLogFilterChange = {},
                onClearLogs = { clears++ },
                onExportLogs = {},
                versionName = "1.0.0",
                buildSha = "unknown",
            )
        }

        composeRule.onNodeWithContentDescription("Clear Log Directory").performClick()
        composeRule.onNodeWithText("Clear log files?").assertIsDisplayed()
        composeRule.onNodeWithText("Cancel").performClick()
        assertEquals(0, clears)

        composeRule.onNodeWithContentDescription("Clear Log Directory").performClick()
        composeRule.onNodeWithText("Clear").performClick()
        assertEquals(1, clears)
    }
}
