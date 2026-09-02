// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.permission.ui

import android.app.Activity
import android.net.Uri
import android.os.Bundle
import androidx.lifecycle.ViewModel
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.x509.KeyChain
import javax.inject.Inject

/**
 * Asks the user to release the certificate an administrator configured for this device.
 *
 * Reached only when the administrator named an alias that the KeyChain will not hand over, which
 * is what a work profile on a personally-owned device looks like: the administrator can install
 * the certificate and configure the app, but only the user can grant an app access to the key.
 * Selecting it once is enough, because the KeyChain remembers the grant.
 */
@HiltViewModel
internal class CertificatePermissionViewModel
    @Inject
    constructor(
        private val repository: Repository,
        private val applicationRestrictions: Bundle,
        private val keyChain: KeyChain,
    ) : ViewModel() {
        /** Runs the KeyChain chooser and reports whether the configured certificate was released. */
        fun chooseCertificate(
            activity: Activity,
            onChosen: (Boolean) -> Unit,
        ) {
            val configuredAlias = repository.getX509CertificateAliasSync(applicationRestrictions)

            // Android answers on a binder thread, so anything touching the UI hops back itself.
            keyChain.choosePrivateKeyAlias(activity, requestUri(), configuredAlias) { alias ->
                // KeyChain takes the configured alias as a pre-selection only, so the user can
                // hand back a different one, which leaves the configured certificate still refused.
                onChosen(alias != null && alias == configuredAlias)
            }
        }

        /** The portal the certificate is meant for, shown by Android in the chooser dialog. */
        private fun requestUri(): Uri? = runCatching { Uri.parse(repository.getConfigSync().apiUrl) }.getOrNull()
    }
