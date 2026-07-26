// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.tunnel

import org.junit.Assert.assertThrows
import org.junit.Test
import uniffi.connlib.CallbackException

class VpnProtectSocketTest {
    @Test
    fun `throws when protect fails`() {
        val protectSocket = VpnProtectSocket { false }

        assertThrows(CallbackException::class.java) { protectSocket.protectSocket(42) }
    }

    @Test
    fun `does not throw without a service`() {
        val protectSocket = VpnProtectSocket { null }

        protectSocket.protectSocket(42)
    }
}
