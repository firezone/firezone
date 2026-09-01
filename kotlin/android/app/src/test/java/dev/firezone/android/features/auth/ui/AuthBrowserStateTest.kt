// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.auth.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class AuthBrowserStateTest {
    @Test
    fun `starts authentication before launching a browser`() {
        val action = AuthBrowserState.NOT_STARTED.resumeAction()

        assertEquals(AuthBrowserState.Action.START_AUTH_FLOW, action)
    }

    @Test
    fun `returns to sign in after restoring a launched browser`() {
        val restoredState = AuthBrowserState.restore(AuthBrowserState.LAUNCHED.name)

        assertEquals(AuthBrowserState.LAUNCHED, restoredState)
        assertEquals(AuthBrowserState.Action.NAVIGATE_TO_SIGN_IN, restoredState.resumeAction())
    }

    @Test
    fun `browser unavailable remains terminal after restoration`() {
        val restoredState = AuthBrowserState.restore(AuthBrowserState.UNAVAILABLE.name)

        assertEquals(AuthBrowserState.UNAVAILABLE, restoredState)
        assertEquals(AuthBrowserState.Action.NONE, restoredState.resumeAction())
    }

    @Test
    fun `acknowledging browser unavailable returns to sign in`() {
        val restoredState = AuthBrowserState.restore(AuthBrowserState.UNAVAILABLE.name)

        assertEquals(
            AuthBrowserState.Action.NAVIGATE_TO_SIGN_IN,
            restoredState.browserRequiredAcknowledgementAction(),
        )
    }

    @Test
    fun `missing saved state starts a new authentication flow`() {
        val restoredState = AuthBrowserState.restore(null)

        assertEquals(AuthBrowserState.NOT_STARTED, restoredState)
    }

    @Test
    fun `unknown saved state starts a new authentication flow`() {
        val restoredState = AuthBrowserState.restore("unknown")

        assertEquals(AuthBrowserState.NOT_STARTED, restoredState)
        assertEquals(AuthBrowserState.Action.START_AUTH_FLOW, restoredState.resumeAction())
    }

    @Test
    fun `browser acknowledgement is ignored unless the browser is unavailable`() {
        assertEquals(
            AuthBrowserState.Action.NONE,
            AuthBrowserState.NOT_STARTED.browserRequiredAcknowledgementAction(),
        )
        assertEquals(
            AuthBrowserState.Action.NONE,
            AuthBrowserState.LAUNCHED.browserRequiredAcknowledgementAction(),
        )
    }
}
