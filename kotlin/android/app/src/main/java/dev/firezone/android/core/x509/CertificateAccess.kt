// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core.x509

import dev.firezone.android.core.Log
import dev.firezone.android.core.data.ManagedConfigurationSource
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.data.model.ManagedConfiguration
import dev.firezone.android.core.di.IoDispatcher
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.withContext
import javax.inject.Inject

/** Answers whether Android must grant Firezone access to the configured certificate. */
internal class CertificateAccess
    @Inject
    constructor(
        private val repository: Repository,
        private val managedConfigurationSource: ManagedConfigurationSource,
        private val keyChain: KeyChain,
        @IoDispatcher private val coroutineDispatcher: CoroutineDispatcher,
    ) {
        /**
         * Whether this device has a configured alias whose certificate Android will not hand over.
         *
         * A personally-owned device carrying a work profile cannot be granted the key by its
         * administrator, and the KeyChain reports the certificate as absent until the user picks it once.
         * A grant that is later revoked, or a certificate that is removed, lands here too, because
         * offering the chooser is more useful than failing later when the tunnel starts.
         */
        suspend fun needsSelection(): Boolean = needsSelection(managedConfigurationSource.refresh())

        internal suspend fun needsSelection(managedConfiguration: ManagedConfiguration): Boolean =
            withContext(coroutineDispatcher) {
                val alias =
                    managedConfiguration.resolveX509CertificateAlias(
                        repository.getUserX509CertificateAliasSync(),
                    )
                        ?: return@withContext false

                try {
                    keyChain.certificateChain(alias).isNullOrEmpty()
                } catch (exception: CancellationException) {
                    throw exception
                } catch (exception: InterruptedException) {
                    Thread.currentThread().interrupt()
                    Log.d(TAG, "Could not check access to the certificate of alias '$alias'", exception)

                    false
                } catch (exception: Exception) {
                    Log.d(TAG, "Could not check access to the certificate of alias '$alias'", exception)

                    false
                }
            }

        private companion object {
            private const val TAG = "CertificateAccess"
        }
    }
