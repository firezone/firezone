// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core.x509

import android.os.Bundle
import dev.firezone.android.core.Log
import dev.firezone.android.core.data.Repository
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import uniffi.x509claims.parseClientCertificate
import javax.inject.Inject

/** Answers whether the app still has to find the device certificate, and whose turn that is. */
class CertificateAccess
    @Inject
    constructor(
        private val repository: Repository,
        private val applicationRestrictions: Bundle,
        private val keyChain: KeyChain,
    ) {
        /**
         * Whether the device policy is worth asking: certificates are not turned off, and no alias
         * the app holds loads as a device certificate.
         */
        suspend fun needsDiscovery(): Boolean =
            withContext(Dispatchers.IO) {
                if (repository.isX509CertificateOff(applicationRestrictions)) {
                    return@withContext false
                }

                val alias =
                    repository.getX509CertificateAliasSync(applicationRestrictions)
                        ?: return@withContext true

                !holdsDeviceCertificate(alias)
            }

        /**
         * Whether the user has to release the certificate: the administrator requires one and the
         * policy did not hand it over, which is what a work profile on a personally-owned device
         * looks like.
         */
        suspend fun needsSelection(): Boolean = repository.isX509CertificateRequired(applicationRestrictions) && needsDiscovery()

        /**
         * Whether the KeyChain hands [alias] over and what it hands over is a device certificate,
         * which is the same test the desktop clients apply when they walk their keystores.
         *
         * Blocks on the KeyChain, so callers stay off the main thread. A KeyChain that cannot be
         * read answers `true`: that failure is the session's to report, not a reason to ask anyone.
         */
        fun holdsDeviceCertificate(alias: String): Boolean =
            try {
                val chain = keyChain.certificateChain(alias)

                !chain.isNullOrEmpty() && parseClientCertificate(chain.first().encoded)?.isDeviceCertificate == true
            } catch (exception: CancellationException) {
                throw exception
            } catch (exception: InterruptedException) {
                Thread.currentThread().interrupt()
                Log.d(TAG, "Could not check access to the certificate of alias '$alias'", exception)

                true
            } catch (exception: Exception) {
                Log.d(TAG, "Could not check access to the certificate of alias '$alias'", exception)

                true
            }

        private companion object {
            private const val TAG = "CertificateAccess"
        }
    }
