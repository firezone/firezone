// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core

import org.junit.Assert.assertEquals
import org.junit.Test
import uniffi.x509claims.ParsedCertificate
import uniffi.x509claims.DetailField
import uniffi.x509claims.parseClientCertificate
import kotlin.reflect.KFunction

/**
 * Prototype smoke test for the x509claims UniFFI bindings: proves they are generated
 * from libconnlib.so and compile into the app. Invoking [parseClientCertificate] needs
 * the Android-built native library, which the host JVM cannot load, so only the
 * compile-time surface is exercised here.
 */
class X509IdentityBindingsTest {
    // Pins the generated top-level function's signature at compile time.
    private val parse: (ByteArray) -> ParsedCertificate? = ::parseClientCertificate

    @Test
    fun `x509claims bindings are reachable`() {
        assertEquals("parseClientCertificate", (parse as KFunction<*>).name)
    }

    @Test
    fun `x509claims records are plain kotlin`() {
        val field = DetailField(label = "Subject", value = "CN=test")

        assertEquals("Subject", field.label)
    }
}
