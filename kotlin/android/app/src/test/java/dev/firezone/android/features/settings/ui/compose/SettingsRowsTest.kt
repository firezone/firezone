// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui.compose

import android.app.Application
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextReplacement
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class SettingsRowsTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun `confirming the dialog stages the edited value`() {
        var staged: String? = null
        composeRule.setContent {
            TextPreferenceRow(title = "Account Slug", value = "old", isManaged = false, onValueChange = { staged = it })
        }

        composeRule.onNodeWithText("Account Slug").performClick()
        composeRule.onNode(hasSetTextAction()).performTextReplacement("new")
        composeRule.onNodeWithText("OK").performClick()

        assertEquals("new", staged)
    }

    @Test
    fun `an invalid value cannot be confirmed`() {
        var staged: String? = null
        composeRule.setContent {
            TextPreferenceRow(
                title = "Log Filter",
                value = "info",
                isManaged = false,
                onValueChange = { staged = it },
                errorMessage = { if (it.isBlank()) "Enter a filter" else null },
            )
        }

        composeRule.onNodeWithText("Log Filter").performClick()
        composeRule.onNode(hasSetTextAction()).performTextReplacement(" ")
        composeRule.onNodeWithText("OK").assertIsNotEnabled()
        composeRule.onNodeWithText("Enter a filter").assertIsDisplayed()

        assertNull(staged)
    }
}
