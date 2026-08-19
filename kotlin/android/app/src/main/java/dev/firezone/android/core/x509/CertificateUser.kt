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
