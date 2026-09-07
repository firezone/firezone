// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core.x509

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.connlib.TlsSignatureScheme
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.spec.ECGenParameterSpec

class KeyChainTlsIdentityTest {
    @Test
    fun `offers PSS ahead of PKCS#1 for a 2048-bit RSA key`() {
        val keyPair = rsaKeyPair(2048)

        assertEquals(
            listOf(
                TlsSignatureScheme.RSA_PSS_SHA256,
                TlsSignatureScheme.RSA_PKCS1_SHA256,
            ),
            KeyChainTlsIdentity.signatureSchemes(keyPair.public),
        )
    }

    @Test
    fun `drops the PSS scheme a 512-bit key has no room for`() {
        val keyPair = rsaKeyPair(512)

        assertEquals(
            listOf(TlsSignatureScheme.RSA_PKCS1_SHA256),
            KeyChainTlsIdentity.signatureSchemes(keyPair.public),
        )
    }

    @Test
    fun `offers the one scheme each NIST curve is paired with`() {
        assertEquals(
            listOf(TlsSignatureScheme.ECDSA_NISTP256_SHA256),
            KeyChainTlsIdentity.signatureSchemes(ecKeyPair("secp256r1").public),
        )
        assertEquals(
            listOf(TlsSignatureScheme.ECDSA_NISTP384_SHA384),
            KeyChainTlsIdentity.signatureSchemes(ecKeyPair("secp384r1").public),
        )
        assertEquals(
            listOf(TlsSignatureScheme.ECDSA_NISTP521_SHA512),
            KeyChainTlsIdentity.signatureSchemes(ecKeyPair("secp521r1").public),
        )
    }

    @Test
    fun `rejects a key that cannot sign a TLS handshake`() {
        val keyPair = KeyPairGenerator.getInstance("DSA").apply { initialize(1024) }.generateKeyPair()

        assertThrows(X509IdentityException::class.java) {
            KeyChainTlsIdentity.signatureSchemes(keyPair.public)
        }
    }

    @Test
    fun `produces signatures that verify with every scheme it offers`() {
        val keyPairs = listOf(rsaKeyPair(2048), ecKeyPair("secp256r1"), ecKeyPair("secp384r1"))

        for (keyPair in keyPairs) {
            for (scheme in KeyChainTlsIdentity.signatureSchemes(keyPair.public)) {
                val signature = KeyChainTlsIdentity.signWith(keyPair.private, scheme, MESSAGE)
                val verified =
                    KeyChainTlsIdentity.signature(scheme).run {
                        initVerify(keyPair.public)
                        update(MESSAGE)
                        verify(signature)
                    }

                assertTrue("$scheme should verify", verified)
            }
        }
    }

    private fun rsaKeyPair(bits: Int): KeyPair = KeyPairGenerator.getInstance("RSA").apply { initialize(bits) }.generateKeyPair()

    private fun ecKeyPair(curve: String): KeyPair =
        KeyPairGenerator
            .getInstance("EC")
            .apply { initialize(ECGenParameterSpec(curve)) }
            .generateKeyPair()

    private companion object {
        private val MESSAGE = "a TLS handshake transcript".toByteArray()
    }
}
