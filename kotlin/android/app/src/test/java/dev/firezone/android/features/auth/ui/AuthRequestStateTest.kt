// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.auth.ui

import androidx.lifecycle.SavedStateHandle
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AuthRequestStateTest {
    @Test
    fun `claims request generation only once while in flight`() {
        val state = AuthRequestState(SavedStateHandle())

        assertTrue(state.claimGeneration())
        assertFalse(state.claimGeneration())
    }

    @Test
    fun `restores issued request without generating another`() {
        val savedState = SavedStateHandle()
        val state = AuthRequestState(savedState)
        check(state.claimGeneration())
        state.markIssued(AUTH_URL)
        state.releaseGeneration()

        val restoredState = AuthRequestState(savedState)

        assertEquals(AUTH_URL, restoredState.issuedUrl)
        assertFalse(restoredState.claimGeneration())
    }

    private companion object {
        private const val AUTH_URL = "https://app.example.com/account?state=state&nonce=nonce"
    }
}
