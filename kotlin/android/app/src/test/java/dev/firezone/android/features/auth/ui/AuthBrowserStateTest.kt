// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.auth.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class AuthBrowserStateTest {
    @Test
    fun `starts authentication before launching a browser`() {
        val action = AuthBrowserState.NOT_STARTED.resumeAction()

        assertEquals(AuthBrowserState.ResumeAction.START_AUTH_FLOW, action)
    }

    @Test
    fun `returns to sign in after restoring a launched browser`() {
        val restoredState = AuthBrowserState.restore(AuthBrowserState.LAUNCHED.name)

        assertEquals(AuthBrowserState.LAUNCHED, restoredState)
        assertEquals(AuthBrowserState.ResumeAction.NAVIGATE_TO_SIGN_IN, restoredState.resumeAction())
    }

    @Test
    fun `browser unavailable remains terminal after restoration`() {
        val restoredState = AuthBrowserState.restore(AuthBrowserState.UNAVAILABLE.name)

        assertEquals(AuthBrowserState.UNAVAILABLE, restoredState)
        assertEquals(AuthBrowserState.ResumeAction.NONE, restoredState.resumeAction())
    }

    @Test
    fun `missing saved state starts a new authentication flow`() {
        val restoredState = AuthBrowserState.restore(null)

        assertEquals(AuthBrowserState.NOT_STARTED, restoredState)
    }
}
