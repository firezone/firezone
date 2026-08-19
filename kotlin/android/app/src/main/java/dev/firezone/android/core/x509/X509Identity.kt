// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core.x509

import android.content.Context
import android.security.KeyChain
import dagger.hilt.android.qualifiers.ApplicationContext
import dev.firezone.android.core.Log
import uniffi.connlib.ClientTlsIdentity
import uniffi.x509claims.ParsedCertificate
import uniffi.x509claims.UserIdentity
import uniffi.x509claims.parseClientCertificate
import java.security.GeneralSecurityException
import java.security.PrivateKey
import java.security.cert.X509Certificate
import javax.inject.Inject
import javax.inject.Singleton

/** The system KeyChain holds no usable client identity under the configured alias. */
class X509IdentityException(
    message: String,
    cause: Throwable? = null,
) : Exception(message, cause)

/**
 * The client identity Firezone presents to the portal, together with what its leaf certificate says.
 *
 * [certificate] is `null` when the leaf is not a certificate the parser understands. The identity
 * stays usable in that case: only the portal decides whether it accepts a certificate.
 */
data class LoadedX509Identity(
    val alias: String,
    val tlsIdentity: ClientTlsIdentity,
    val certificateCount: Int,
    val certificate: ParsedCertificate?,
) {
    /** The portal user this certificate authenticates, if it names a complete one. */
    val userIdentity: UserIdentity?
        get() = certificate?.userIdentity
}

/**
 * Reads client identities out of Android's system KeyChain.
 *
 * Every call reaches the KeyChain system service and blocks, so callers must stay off the main
 * thread.
 */
@Singleton
class X509Identity
    @Inject
    constructor(
        @param:ApplicationContext private val context: Context,
    ) {
        /**
         * Loads the identity stored under [alias], or `null` when no alias is configured.
         *
         * @throws X509IdentityException if an alias is configured but yields no usable identity.
         */
        fun load(alias: String?): LoadedX509Identity? {
            if (alias == null) {
                Log.d(TAG, "No KeyChain alias is configured for mutual TLS")

                return null
            }

            val chain = certificateChain(alias)
            val privateKey = privateKey(alias)
            val leaf = chain.first()

            if (privateKey.algorithm != leaf.publicKey.algorithm) {
                throw X509IdentityException(
                    "Alias '$alias' pairs a ${privateKey.algorithm} key with a ${leaf.publicKey.algorithm} certificate.",
                )
            }

            val tlsIdentity =
                try {
                    KeyChainTlsIdentity(alias, chain, privateKey)
                } catch (exception: GeneralSecurityException) {
                    throw X509IdentityException(
                        "The certificate chain of alias '$alias' could not be encoded.",
                        exception,
                    )
                }
            val certificate = parseClientCertificate(tlsIdentity.certificateChain().first())

            Log.i(
                TAG,
                "Loaded the client identity of alias '$alias' " +
                    "(certificates=${chain.size}, fingerprint=${certificate?.fingerprint ?: "unparsed"})",
            )

            return LoadedX509Identity(
                alias = alias,
                tlsIdentity = tlsIdentity,
                certificateCount = chain.size,
                certificate = certificate,
            )
        }

        private fun certificateChain(alias: String): List<X509Certificate> {
            val chain =
                try {
                    KeyChain.getCertificateChain(context, alias)
                } catch (exception: InterruptedException) {
                    Thread.currentThread().interrupt()

                    throw X509IdentityException(
                        "Reading the certificate chain of alias '$alias' was interrupted.",
                        exception,
                    )
                } catch (exception: Exception) {
                    throw X509IdentityException(
                        "The certificate chain of alias '$alias' could not be read.",
                        exception,
                    )
                }

            if (chain == null || chain.isEmpty()) {
                throw X509IdentityException(
                    "Alias '$alias' holds no certificate, or Firezone has not been granted access to it.",
                )
            }

            return chain.toList()
        }

        private fun privateKey(alias: String): PrivateKey {
            val privateKey =
                try {
                    KeyChain.getPrivateKey(context, alias)
                } catch (exception: InterruptedException) {
                    Thread.currentThread().interrupt()

                    throw X509IdentityException(
                        "Opening the private key of alias '$alias' was interrupted.",
                        exception,
                    )
                } catch (exception: Exception) {
                    throw X509IdentityException(
                        "The private key of alias '$alias' could not be opened.",
                        exception,
                    )
                }

            return privateKey
                ?: throw X509IdentityException(
                    "Alias '$alias' holds no private key, or Firezone has not been granted access to it.",
                )
        }

        private companion object {
            private const val TAG = "X509Identity"
        }
    }
