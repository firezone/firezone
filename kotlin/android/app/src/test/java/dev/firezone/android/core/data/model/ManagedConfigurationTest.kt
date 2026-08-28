// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core.data.model

import android.app.Application
import android.os.Bundle
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class)
class ManagedConfigurationTest {
    @Test
    fun `parsing preserves absent and explicit boolean values`() {
        val configuration =
            ManagedConfiguration.from(
                Bundle().apply {
                    putBoolean("connectOnStart", false)
                },
            )

        assertFalse(configuration.connectOnStart!!)
        assertNull(configuration.startOnLogin)
    }

    @Test
    fun `session settings require reconnect`() {
        val previous = ManagedConfiguration()

        assertTrue(ManagedConfiguration(token = "token").requiresSessionReconnect(previous))
        assertTrue(ManagedConfiguration().requiresSessionReconnect(ManagedConfiguration(token = "token")))
        assertTrue(ManagedConfiguration(deviceName = "managed-device").requiresSessionReconnect(previous))
        assertTrue(ManagedConfiguration(apiUrl = "wss://api.example.com").requiresSessionReconnect(previous))
        assertTrue(ManagedConfiguration(accountSlug = "example").requiresSessionReconnect(previous))
        assertFalse(ManagedConfiguration(authUrl = "https://app.example.com").requiresSessionReconnect(previous))
        assertFalse(ManagedConfiguration(logFilter = "debug").requiresSessionReconnect(previous))
        assertFalse(ManagedConfiguration(startOnLogin = true).requiresSessionReconnect(previous))
        assertFalse(ManagedConfiguration(connectOnStart = true).requiresSessionReconnect(previous))
    }

    @Test
    fun `application routing settings require VPN rebuild`() {
        val previous = ManagedConfiguration()

        assertTrue(ManagedConfiguration(allowedApplications = "com.example.allowed").requiresVpnRebuild(previous))
        assertTrue(ManagedConfiguration(disallowedApplications = "com.example.blocked").requiresVpnRebuild(previous))
        assertFalse(ManagedConfiguration(token = "token").requiresVpnRebuild(previous))
    }
}
