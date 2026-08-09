// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core.x509

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.connlib.TlsSignatureScheme
import java.security.KeyPairGenerator
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.security.spec.MGF1ParameterSpec
import java.security.spec.PSSParameterSpec

class X509IdentityTest {
    @Test
    fun `supports managed profiles and device-owner devices only`() {
        assertTrue(X509Identity.isSupportedProfile(isManagedProfile = true, hasDeviceOwner = false))
        assertTrue(X509Identity.isSupportedProfile(isManagedProfile = false, hasDeviceOwner = true))
        assertTrue(X509Identity.isSupportedProfile(isManagedProfile = true, hasDeviceOwner = true))
        assertFalse(X509Identity.isSupportedProfile(isManagedProfile = false, hasDeviceOwner = false))
    }

    @Test
    fun `signs TLS handshake with RSA-PSS SHA-256`() {
        val keyPair = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.generateKeyPair()
        val message = ByteArray(96) { it.toByte() }
        val scheme = TlsSignatureScheme.RSA_PSS_SHA256

        val signature = X509Identity.sign(keyPair.private, scheme, message)

        assertTrue(X509Identity.supportedSignatureSchemes(keyPair.public).contains(scheme))
        assertTrue(verify(scheme, keyPair.public, message, signature))
    }

    @Test
    fun `signs P-256 challenge with SHA-256`() {
        val keyPair = ecKeyPair("secp256r1")
        val message = ByteArray(96) { (it + 1).toByte() }
        val scheme = TlsSignatureScheme.ECDSA_NISTP256_SHA256

        val signature = X509Identity.sign(keyPair.private, scheme, message)

        assertEquals(listOf(scheme), X509Identity.supportedSignatureSchemes(keyPair.public))
        assertTrue(verify(scheme, keyPair.public, message, signature))
    }

    @Test
    fun `signs P-384 challenge with SHA-384`() {
        val keyPair = ecKeyPair("secp384r1")
        val message = ByteArray(96) { (it + 2).toByte() }
        val scheme = TlsSignatureScheme.ECDSA_NISTP384_SHA384

        val signature = X509Identity.sign(keyPair.private, scheme, message)

        assertEquals(listOf(scheme), X509Identity.supportedSignatureSchemes(keyPair.public))
        assertTrue(verify(scheme, keyPair.public, message, signature))
    }

    @Test
    fun `rejects unsupported key algorithms`() {
        val keyPair = KeyPairGenerator.getInstance("DSA").apply { initialize(2048) }.generateKeyPair()

        assertThrows(X509IdentityException::class.java) {
            X509Identity.supportedSignatureSchemes(keyPair.public)
        }
    }

    @Test
    fun `formats readable subject alternative names`() {
        assertEquals(
            "URI: firezone://intune-id/4125c235-441b-48b7-b96d-1c17494931a2",
            X509Identity.formatSubjectAlternativeName(
                6,
                "firezone://intune-id/4125c235-441b-48b7-b96d-1c17494931a2",
            ),
        )
        assertEquals(
            "DNS: device.example.com",
            X509Identity.formatSubjectAlternativeName(2, "device.example.com"),
        )
        assertEquals(
            "Other name: DER/Base64 AQID",
            X509Identity.formatSubjectAlternativeName(0, byteArrayOf(1, 2, 3)),
        )
    }

    @Test
    fun `extracts and normalizes MDM device ID from typed URI SAN`() {
        assertEquals(
            "4125c235-441b-48b7-b96d-1c17494931a2",
            X509Identity.mdmDeviceId(
                listOf(
                    "firezone://serial/ABC123",
                    "firezone://intune-id/4125C235-441B-48B7-B96D-1C17494931A2",
                ),
            ),
        )
    }

    @Test
    fun `extracts MDM device ID from Intune comma-joined URI SAN`() {
        assertEquals(
            "4125c235-441b-48b7-b96d-1c17494931a2",
            X509Identity.mdmDeviceId(
                listOf(
                    "tag:microsoft.com,2022-09-14:sid:S-1-12-1-1, " +
                        "firezone://serial/ABC123, " +
                        "firezone://intune-id/4125C235-441B-48B7-B96D-1C17494931A2",
                ),
            ),
        )
    }

    @Test
    fun `uses bare UUID fallback only when typed identifiers are absent`() {
        val bareId = "4125c235-441b-48b7-b96d-1c17494931a2"

        assertEquals(bareId, X509Identity.mdmDeviceId(listOf(bareId)))
        assertEquals(
            null,
            X509Identity.mdmDeviceId(listOf("firezone://serial/ABC123", bareId)),
        )
    }

    @Test
    fun `rejects sentinel MDM identifiers`() {
        assertEquals(
            null,
            X509Identity.mdmDeviceId(
                listOf("firezone://intune-id/00000000-0000-0000-0000-000000000000"),
            ),
        )
    }

    private fun ecKeyPair(curve: String) =
        KeyPairGenerator
            .getInstance("EC")
            .apply { initialize(ECGenParameterSpec(curve)) }
            .generateKeyPair()

    private fun verify(
        scheme: TlsSignatureScheme,
        publicKey: java.security.PublicKey,
        message: ByteArray,
        signature: ByteArray,
    ): Boolean =
        Signature
            .getInstance(
                if (scheme == TlsSignatureScheme.RSA_PSS_SHA256) {
                    "RSASSA-PSS"
                } else {
                    X509Identity.signatureAlgorithm(scheme)
                },
            ).run {
                initVerify(publicKey)
                if (scheme == TlsSignatureScheme.RSA_PSS_SHA256) {
                    setParameter(PSSParameterSpec("SHA-256", "MGF1", MGF1ParameterSpec.SHA256, 32, 1))
                }
                update(message)
                verify(signature)
            }
}
