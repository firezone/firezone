// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UrlValidationTest {
    @Test
    fun `auth URLs accept http and https`() {
        assertTrue(isValidAuthUrl("http://localhost:4000"))
        assertTrue(isValidAuthUrl("https://firezone.example.com"))
    }

    @Test
    fun `api URLs accept ws and wss`() {
        assertTrue(isValidApiUrl("ws://localhost:8081"))
        assertTrue(isValidApiUrl("wss://api.firezone.example.com"))
    }

    @Test
    fun `auth URLs reject other schemes and missing hosts`() {
        assertFalse(isValidAuthUrl("ftp://x"))
        assertFalse(isValidAuthUrl("example.com"))
        assertFalse(isValidAuthUrl("https://"))
        assertFalse(isValidAuthUrl("wss://api.firezone.example.com"))
    }

    @Test
    fun `api URLs reject other schemes and missing hosts`() {
        assertFalse(isValidApiUrl("ftp://x"))
        assertFalse(isValidApiUrl("example.com"))
        assertFalse(isValidApiUrl("wss://"))
        assertFalse(isValidApiUrl("https://firezone.example.com"))
    }
}
