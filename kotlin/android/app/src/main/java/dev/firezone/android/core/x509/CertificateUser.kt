// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core.x509

import android.os.Bundle
import dev.firezone.android.core.Log
import dev.firezone.android.core.data.Repository
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import uniffi.x509claims.UserIdentity
import javax.inject.Inject

/**
 * Answers whom the configured client certificate authenticates.
 *
 * The sign-in screens use this to decide whether a browser sign-in is still needed and whom to name
 * while they wait. Failures end up as "nobody" and stay at debug level: the tunnel loads the
 * identity itself and is the one that reports a broken keystore to the user and to telemetry.
 */
class CertificateUser
    @Inject
    constructor(
        private val repository: Repository,
        private val applicationRestrictions: Bundle,
        private val x509Identity: X509Identity,
    ) {
        /**
         * Whether an administrator configured a certificate that this device will not release on
         * its own.
         *
         * A managed alias says the administrator means this device to authenticate by certificate.
         * On a company-owned device they grant us the key as well, so reading it succeeds and
         * nobody is asked anything. On a personally-owned device carrying a work profile they
         * cannot grant it, and the KeyChain reports the alias as absent until the user picks it
         * once. Any other failure to read a managed alias lands here too, because offering the
         * chooser is more useful to the user than a screen they cannot act on.
         */
        suspend fun needsSelection(): Boolean =
            withContext(Dispatchers.IO) {
                if (!repository.isX509CertificateAliasManaged(applicationRestrictions)) {
                    return@withContext false
                }

                val alias =
                    repository.getX509CertificateAliasSync(applicationRestrictions)
                        ?: return@withContext false

                try {
                    x509Identity.load(alias) == null
                } catch (exception: CancellationException) {
                    throw exception
                } catch (exception: Exception) {
                    Log.d(TAG, "The managed alias '$alias' needs to be selected by the user", exception)

                    true
                }
            }

        suspend fun identity(): UserIdentity? =
            withContext(Dispatchers.IO) {
                try {
                    x509Identity
                        .load(repository.getX509CertificateAliasSync(applicationRestrictions))
                        ?.userIdentity
                } catch (exception: CancellationException) {
                    throw exception
                } catch (exception: Exception) {
                    Log.d(TAG, "Could not read the configured client certificate", exception)

                    null
                }
            }

        private companion object {
            private const val TAG = "CertificateUser"
        }
    }
