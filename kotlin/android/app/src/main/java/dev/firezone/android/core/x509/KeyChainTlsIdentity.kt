// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core.x509

import dev.firezone.android.core.Log
import uniffi.connlib.CallbackException
import uniffi.connlib.ClientTlsIdentity
import uniffi.connlib.TlsSignatureScheme
import java.security.PrivateKey
import java.security.PublicKey
import java.security.Signature
import java.security.cert.X509Certificate
import java.security.interfaces.ECPublicKey
import java.security.interfaces.RSAPublicKey
import java.security.spec.MGF1ParameterSpec
import java.security.spec.PSSParameterSpec

/**
 * A client identity whose private key stays inside Android's system KeyChain.
 *
 * The key is non-exportable and may be hardware-backed, so every handshake signature is produced by
 * the keystore instead of from key material we hold. connlib reads the chain and the supported
 * schemes while it builds the session, so both are captured here rather than fetched from the
 * KeyChain on whichever thread happens to ask.
 */
internal class KeyChainTlsIdentity(
    private val alias: String,
    chain: List<X509Certificate>,
    private val privateKey: PrivateKey,
) : ClientTlsIdentity {
    private val encodedChain = chain.map { certificate -> certificate.encoded }
    private val schemes = signatureSchemes(chain.first().publicKey)

    override fun certificateChain(): List<ByteArray> = encodedChain

    override fun supportedSignatureSchemes(): List<TlsSignatureScheme> = schemes

    override fun sign(
        scheme: TlsSignatureScheme,
        message: ByteArray,
    ): ByteArray =
        try {
            signWith(privateKey, scheme, message)
        } catch (exception: Exception) {
            Log.e(TAG, "The KeyChain failed to sign a TLS handshake message", exception)

            throw CallbackException.Failed(
                exception.message ?: "The Android KeyChain refused to sign with alias '$alias'.",
            )
        }

    override fun toString(): String = "KeyChainTlsIdentity(alias=$alias)"

    internal companion object {
        private const val TAG = "KeyChainTlsIdentity"

        /**
         * The signature schemes [publicKey] can sign with, most preferred first.
         *
         * connlib requires all of them to belong to the same key algorithm and picks the first one
         * the portal also offers.
         */
        internal fun signatureSchemes(publicKey: PublicKey): List<TlsSignatureScheme> =
            when (publicKey) {
                is RSAPublicKey -> {
                    rsaSchemes(publicKey.modulus.bitLength())
                }

                is ECPublicKey -> {
                    ecdsaSchemes(publicKey.params.curve.field.fieldSize)
                }

                else -> {
                    throw X509IdentityException(
                        "The certificate holds a ${publicKey.algorithm} key, which cannot sign a TLS handshake.",
                    )
                }
            }

        /**
         * The RSA schemes a [modulusBits]-bit key has room for, strongest first.
         *
         * PSS needs the digest, a salt of the same length and two more bytes; PKCS#1 v1.5 needs the
         * digest, its 19-byte DigestInfo header and at least 11 bytes of padding.
         */
        private fun rsaSchemes(modulusBits: Int): List<TlsSignatureScheme> =
            listOfNotNull(
                TlsSignatureScheme.RSA_PSS_SHA512.takeIf { modulusBits >= 8 * (64 + 64 + 2) },
                TlsSignatureScheme.RSA_PSS_SHA384.takeIf { modulusBits >= 8 * (48 + 48 + 2) },
                TlsSignatureScheme.RSA_PSS_SHA256.takeIf { modulusBits >= 8 * (32 + 32 + 2) },
                TlsSignatureScheme.RSA_PKCS1_SHA512.takeIf { modulusBits >= 8 * (64 + 19 + 11) },
                TlsSignatureScheme.RSA_PKCS1_SHA384.takeIf { modulusBits >= 8 * (48 + 19 + 11) },
                TlsSignatureScheme.RSA_PKCS1_SHA256.takeIf { modulusBits >= 8 * (32 + 19 + 11) },
            ).ifEmpty {
                throw X509IdentityException(
                    "The certificate holds a $modulusBits-bit RSA key, which is too small to sign a TLS handshake.",
                )
            }

        /**
         * The ECDSA scheme for a curve over a [fieldSizeBits]-bit field.
         *
         * TLS pins the digest to the curve, so a key has exactly one scheme to offer.
         */
        private fun ecdsaSchemes(fieldSizeBits: Int): List<TlsSignatureScheme> =
            when (fieldSizeBits) {
                256 -> {
                    listOf(TlsSignatureScheme.ECDSA_NISTP256_SHA256)
                }

                384 -> {
                    listOf(TlsSignatureScheme.ECDSA_NISTP384_SHA384)
                }

                521 -> {
                    listOf(TlsSignatureScheme.ECDSA_NISTP521_SHA512)
                }

                else -> {
                    throw X509IdentityException(
                        "The certificate holds an EC key on an unsupported $fieldSizeBits-bit curve.",
                    )
                }
            }

        /** Signs [message] with [privateKey] the way [scheme] prescribes. */
        internal fun signWith(
            privateKey: PrivateKey,
            scheme: TlsSignatureScheme,
            message: ByteArray,
        ): ByteArray =
            signature(scheme).run {
                initSign(privateKey)
                update(message)
                sign()
            }

        /** A [Signature] configured for [scheme], ready to be initialised with a key. */
        internal fun signature(scheme: TlsSignatureScheme): Signature =
            when (scheme) {
                TlsSignatureScheme.RSA_PKCS1_SHA256 -> {
                    Signature.getInstance("SHA256withRSA")
                }

                TlsSignatureScheme.RSA_PKCS1_SHA384 -> {
                    Signature.getInstance("SHA384withRSA")
                }

                TlsSignatureScheme.RSA_PKCS1_SHA512 -> {
                    Signature.getInstance("SHA512withRSA")
                }

                TlsSignatureScheme.RSA_PSS_SHA256 -> {
                    pssSignature("SHA256withRSA/PSS", "SHA-256", MGF1ParameterSpec.SHA256, saltLength = 32)
                }

                TlsSignatureScheme.RSA_PSS_SHA384 -> {
                    pssSignature("SHA384withRSA/PSS", "SHA-384", MGF1ParameterSpec.SHA384, saltLength = 48)
                }

                TlsSignatureScheme.RSA_PSS_SHA512 -> {
                    pssSignature("SHA512withRSA/PSS", "SHA-512", MGF1ParameterSpec.SHA512, saltLength = 64)
                }

                TlsSignatureScheme.ECDSA_NISTP256_SHA256 -> {
                    Signature.getInstance("SHA256withECDSA")
                }

                TlsSignatureScheme.ECDSA_NISTP384_SHA384 -> {
                    Signature.getInstance("SHA384withECDSA")
                }

                TlsSignatureScheme.ECDSA_NISTP521_SHA512 -> {
                    Signature.getInstance("SHA512withECDSA")
                }
            }

        /**
         * A PSS [Signature], preferring the digest-specific [algorithm].
         *
         * Android's digest-specific implementations fix the digest, the MGF digest and the salt
         * length themselves, and their KeyChain-backed variant rejects `setParameter`. Providers
         * that only offer the generic `RSASSA-PSS` algorithm need those parameters spelled out.
         */
        private fun pssSignature(
            algorithm: String,
            digest: String,
            mgf1: MGF1ParameterSpec,
            saltLength: Int,
        ): Signature =
            runCatching { Signature.getInstance(algorithm) }.getOrElse {
                Signature.getInstance("RSASSA-PSS").apply {
                    setParameter(PSSParameterSpec(digest, "MGF1", mgf1, saltLength, 1))
                }
            }
    }
}
