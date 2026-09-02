// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core.data.model

import android.app.Application
import android.os.Bundle
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config as RobolectricConfig

@RunWith(RobolectricTestRunner::class)
@RobolectricConfig(application = Application::class)
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

    @Test
    fun `absent managed token uses the saved user token`() {
        assertEquals(
            SessionCredential("user-token", CredentialOrigin.USER),
            ManagedConfiguration().resolveSessionCredential("user-token"),
        )
    }

    @Test
    fun `blank managed token explicitly disables the saved user token`() {
        assertNull(ManagedConfiguration(token = "").resolveSessionCredential("user-token"))
    }

    @Test
    fun `managed token records its credential origin`() {
        assertEquals(
            SessionCredential("managed-token", CredentialOrigin.MANAGED),
            ManagedConfiguration(token = "managed-token").resolveSessionCredential("user-token"),
        )
    }

    @Test
    fun `managed authentication failure preserves saved user credentials`() {
        assertFalse(CredentialOrigin.MANAGED.shouldClearSavedCredentials(requiresSignIn = true))
        assertTrue(CredentialOrigin.USER.shouldClearSavedCredentials(requiresSignIn = true))
    }

    @Test
    fun `effective config and mask come from one managed snapshot`() {
        val userConfig =
            Config(
                authUrl = "https://user.example.com",
                apiUrl = "wss://user.example.com",
                logFilter = "info",
                accountSlug = "user-account",
                startOnLogin = false,
                connectOnStart = false,
            )
        val snapshot =
            ManagedConfiguration(
                authUrl = "https://managed.example.com",
                apiUrl = "wss://managed.example.com",
                connectOnStart = true,
            )

        assertEquals(
            userConfig.copy(
                authUrl = "https://managed.example.com",
                apiUrl = "wss://managed.example.com",
                connectOnStart = true,
            ),
            snapshot.applyTo(userConfig),
        )
        assertEquals(
            ManagedConfigStatus(
                isAuthUrlManaged = true,
                isApiUrlManaged = true,
                isLogFilterManaged = false,
                isAccountSlugManaged = false,
                isStartOnLoginManaged = false,
                isConnectOnStartManaged = true,
            ),
            snapshot.managedStatus(),
        )
    }
}
