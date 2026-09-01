// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core.x509

import android.os.Bundle
import dev.firezone.android.core.Log
import dev.firezone.android.core.data.Repository
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import javax.inject.Inject

/** Answers whether Android must grant Firezone access to the configured certificate. */
class CertificateAccess
    @Inject
    constructor(
        private val repository: Repository,
        private val applicationRestrictions: Bundle,
        private val x509Identity: X509Identity,
    ) {
        /**
         * Whether this device has a configured alias whose key Android will not hand over.
         *
         * A personally-owned device carrying a work profile cannot be granted the key by its
         * administrator, and the KeyChain reports the alias as absent until the user picks it once.
         * A grant that is later revoked, or a certificate that is removed, lands here too, because
         * offering the chooser is more useful than failing later when the tunnel starts.
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

        private companion object {
            private const val TAG = "CertificateAccess"
        }
    }
