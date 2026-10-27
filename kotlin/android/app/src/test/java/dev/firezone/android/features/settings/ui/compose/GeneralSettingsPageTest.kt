// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui.compose

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextReplacement
import dev.firezone.android.R
import dev.firezone.android.core.data.model.ManagedConfigStatus
import dev.firezone.android.core.data.model.Portal
import dev.firezone.android.core.data.model.SignInConfig
import dev.firezone.android.core.data.model.signInConfig
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import dev.firezone.android.core.data.model.Config as FirezoneConfig

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class GeneralSettingsPageTest {
    @get:Rule
    val composeRule = createComposeRule()

    private val note = RuntimeEnvironment.getApplication().getString(R.string.sign_in_change_note)

    private var config by mutableStateOf(
        FirezoneConfig(
            authUrl = "https://app.firezone.dev",
            apiUrl = "wss://api.firezone.dev",
            logFilter = "info",
            accountSlug = "example-corp",
            startOnLogin = false,
            connectOnStart = false,
        ),
    )
    private var signedInWith by mutableStateOf<SignInConfig?>(null)

    private fun showPage() {
        composeRule.setContent {
            GeneralSettingsPage(
                config = config,
                portal = Portal.CLOUD_US,
                managedStatus = ManagedConfigStatus.NOTHING_MANAGED,
                signedInWith = signedInWith,
                onPortalChange = {},
                onAuthUrlChange = {},
                onApiUrlChange = {},
                onAccountSlugChange = {},
                onStartOnLoginChange = {},
                onConnectOnStartChange = {},
            )
        }
    }

    @Test
    fun `the note stays hidden while signed out`() {
        showPage()
        config = config.copy(accountSlug = "other-corp")
        composeRule.onNodeWithText(note).assertDoesNotExist()

        composeRule.onNodeWithText("Account Slug").performClick()
        composeRule.onNode(hasSetTextAction()).performTextReplacement("another-corp")
        composeRule.onNodeWithText(note).assertDoesNotExist()
    }

    @Test
    fun `the note shows while saved values differ from the session's`() {
        val original = config
        signedInWith = original.signInConfig()
        showPage()
        composeRule.onNodeWithText(note).assertDoesNotExist()

        config = original.copy(accountSlug = "other-corp")
        composeRule.onNodeWithText(note).assertIsDisplayed()

        config = original
        composeRule.onNodeWithText(note).assertDoesNotExist()

        config = original.copy(accountSlug = "other-corp")
        signedInWith = config.signInConfig()
        composeRule.onNodeWithText(note).assertDoesNotExist()
    }

    @Test
    fun `the dialogs note an edit as soon as it differs from the session's`() {
        signedInWith = config.signInConfig()
        showPage()

        composeRule.onNodeWithText("Account Slug").performClick()
        composeRule.onNode(hasSetTextAction()).performTextReplacement("other-corp")
        composeRule.onNodeWithText(note).assertIsDisplayed()
        composeRule.onNode(hasSetTextAction()).performTextReplacement("example-corp")
        composeRule.onNodeWithText(note).assertDoesNotExist()
        composeRule.onNodeWithText("Cancel").performClick()

        composeRule.onNodeWithText("Control plane").performClick()
        composeRule.onNodeWithText(note).assertIsDisplayed()
    }
}
