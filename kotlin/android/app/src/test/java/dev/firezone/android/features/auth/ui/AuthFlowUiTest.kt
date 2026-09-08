// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.auth.ui

import android.app.Application
import dev.firezone.android.features.auth.AuthCallbackOutcome
import dev.firezone.android.features.auth.PendingAuthSession
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class)
class AuthFlowUiTest {
    @Test
    fun `the fabricated callback completes the request it was built from`() {
        val session = PendingAuthSession()
        session.begin(nonce = "nonce-", state = STATE)

        val outcome = session.complete(fabricatedAuthCallback(authUrl(STATE)))

        assertTrue(outcome is AuthCallbackOutcome.Success)
    }

    @Test
    fun `a callback fabricated for another request is refused`() {
        val session = PendingAuthSession()
        session.begin(nonce = "nonce-", state = STATE)

        val outcome = session.complete(fabricatedAuthCallback(authUrl("a-different-state")))

        assertEquals(AuthCallbackOutcome.Error("Invalid state parameter"), outcome)
    }

    private fun authUrl(state: String) = "https://app.firezone.dev/example-corp?state=$state&nonce=nonce-&as=gui-client"

    private companion object {
        const val STATE = "the-state-the-request-issued"
    }
}
