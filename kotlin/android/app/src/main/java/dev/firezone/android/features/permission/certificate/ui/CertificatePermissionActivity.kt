// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.permission.certificate.ui

import android.net.Uri
import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.appcompat.app.AppCompatActivity
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.R
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.x509.CertificateAccess
import dev.firezone.android.core.x509.KeyChain
import dev.firezone.android.features.permission.certificate.ui.compose.CertificatePermissionScreen
import dev.firezone.android.features.session.ui.compose.FirezoneTheme
import javax.inject.Inject

/**
 * Has the user release the device certificate an administrator requires.
 *
 * Reached only when the administrator requires a certificate that the device policy did not hand
 * over, which is what a work profile on a personally-owned device looks like: the administrator can
 * install the certificate, but only the user can grant an app access to the key. Selecting it once
 * is enough, because the KeyChain remembers the grant and we remember the alias.
 */
@AndroidEntryPoint
class CertificatePermissionActivity : AppCompatActivity() {
    @Inject
    lateinit var repository: Repository

    @Inject
    lateinit var certificateAccess: CertificateAccess

    @Inject
    lateinit var keyChain: KeyChain

    private var error by mutableStateOf<String?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        setContent {
            FirezoneTheme {
                CertificatePermissionScreen(
                    onSelectCertificate = ::chooseCertificate,
                    error = error,
                )
            }
        }
    }

    private fun chooseCertificate() {
        // Android answers on a binder thread, where reading the KeyChain back is fine and anything
        // touching the UI hops back itself.
        keyChain.choosePrivateKeyAlias(this, requestUri(), null) { alias ->
            val message =
                when {
                    alias == null -> getString(R.string.device_trust_no_certificate_selected)
                    !certificateAccess.holdsDeviceCertificate(alias) -> getString(R.string.device_trust_not_device_certificate, alias)
                    else -> null
                }

            if (message == null) {
                repository.saveX509CertificateAliasSync(alias)
            }

            runOnUiThread {
                if (message == null) {
                    finish()
                } else {
                    error = message
                }
            }
        }
    }

    /** The portal the certificate is meant for, shown by Android in the chooser dialog. */
    private fun requestUri(): Uri? = runCatching { Uri.parse(repository.getConfigSync().apiUrl) }.getOrNull()
}
