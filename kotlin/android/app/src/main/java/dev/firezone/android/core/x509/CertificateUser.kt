// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core.x509

import android.os.Bundle
import dev.firezone.android.core.Log
import dev.firezone.android.core.data.Repository
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import uniffi.x509claims.Identity
import javax.inject.Inject

/**
 * Answers whom the configured client certificate authenticates.
 *
 * The sign-in screens use this to decide what to offer and whom to name while they wait. Failures
 * end up as [Identity.Absent] and stay at debug level: the tunnel loads the identity itself and is
 * the one that reports a broken keystore to the user and to telemetry.
 */
class CertificateUser
    @Inject
    constructor(
        private val repository: Repository,
        private val applicationRestrictions: Bundle,
        private val x509Identity: X509Identity,
    ) {
        /**
         * Whether this device is configured to authenticate by certificate but cannot read the one
         * it was given.
         *
         * A configured alias says this device is meant to authenticate by certificate, whether an
         * administrator chose it or the user did. Where the key is granted to us the read succeeds
         * and nobody is asked anything, which is what keeps unattended devices unattended. A
         * personally-owned device carrying a work profile cannot be granted the key by its
         * administrator, and the KeyChain reports the alias as absent until the user picks it once.
         * A grant that is later revoked, or a certificate that is removed, lands here too, because
         * offering the chooser is more useful than silently falling back to a browser sign-in.
         */
        suspend fun needsSelection(): Boolean =
            withContext(Dispatchers.IO) {
                val alias =
                    repository.getX509CertificateAliasSync(applicationRestrictions)
                        ?: return@withContext false

                try {
                    x509Identity.load(alias) == null
                } catch (exception: CancellationException) {
                    throw exception
                } catch (exception: Exception) {
                    Log.d(TAG, "The alias '$alias' needs to be selected by the user", exception)

                    true
                }
            }

        suspend fun identity(): Identity =
            withContext(Dispatchers.IO) {
                try {
                    x509Identity
                        .load(repository.getX509CertificateAliasSync(applicationRestrictions))
                        ?.identity
                        ?: Identity.Absent
                } catch (exception: CancellationException) {
                    throw exception
                } catch (exception: Exception) {
                    Log.d(TAG, "Could not read the configured client certificate", exception)

                    Identity.Absent
                }
            }

        private companion object {
            private const val TAG = "CertificateUser"
        }
    }
