// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.permission.ui

import android.app.Activity
import android.net.Uri
import androidx.lifecycle.ViewModel
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.x509.CertificateAccess
import dev.firezone.android.core.x509.KeyChain
import javax.inject.Inject

/**
 * Has the user release the device certificate an administrator requires.
 *
 * Reached only when the administrator requires a certificate that the device policy did not hand
 * over, which is what a work profile on a personally-owned device looks like: the administrator can
 * install the certificate, but only the user can grant an app access to the key. Selecting it once
 * is enough, because the KeyChain remembers the grant and we remember the alias.
 */
@HiltViewModel
internal class CertificatePermissionViewModel
    @Inject
    constructor(
        private val repository: Repository,
        private val certificateAccess: CertificateAccess,
        private val keyChain: KeyChain,
    ) : ViewModel() {
        /** Runs the KeyChain chooser and reports what came back. */
        fun chooseCertificate(
            activity: Activity,
            onChosen: (Outcome) -> Unit,
        ) {
            // Android answers on a binder thread, where reading the KeyChain back is fine and
            // anything touching the UI hops back itself.
            keyChain.choosePrivateKeyAlias(activity, requestUri(), null) { alias ->
                val outcome =
                    when {
                        alias == null -> Outcome.NothingSelected
                        !certificateAccess.holdsDeviceCertificate(alias) -> Outcome.NotADeviceCertificate(alias)
                        else -> {
                            repository.saveX509CertificateAliasSync(alias)
                            Outcome.Selected
                        }
                    }

                onChosen(outcome)
            }
        }

        /** The portal the certificate is meant for, shown by Android in the chooser dialog. */
        private fun requestUri(): Uri? = runCatching { Uri.parse(repository.getConfigSync().apiUrl) }.getOrNull()

        internal sealed interface Outcome {
            data object Selected : Outcome

            data object NothingSelected : Outcome

            data class NotADeviceCertificate(
                val alias: String,
            ) : Outcome
        }
    }
