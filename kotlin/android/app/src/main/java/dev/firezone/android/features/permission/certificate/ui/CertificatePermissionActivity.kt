// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.permission.certificate.ui

import android.net.Uri
import android.os.Bundle
import android.widget.Toast
import androidx.activity.compose.setContent
import androidx.appcompat.app.AppCompatActivity
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.R
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.x509.KeyChain
import dev.firezone.android.features.permission.certificate.ui.compose.CertificatePermissionScreen
import dev.firezone.android.ui.theme.FirezoneTheme
import javax.inject.Inject

/**
 * Asks the user to release the certificate an administrator configured for this device.
 *
 * Reached only when the administrator named an alias that the KeyChain will not hand over, which
 * is what a work profile on a personally-owned device looks like: the administrator can install
 * the certificate and configure the app, but only the user can grant an app access to the key.
 * Selecting it once is enough, because the KeyChain remembers the grant.
 */
@AndroidEntryPoint
class CertificatePermissionActivity : AppCompatActivity() {
    @Inject
    lateinit var repository: Repository

    @Inject
    lateinit var applicationRestrictions: Bundle

    @Inject
    lateinit var keyChain: KeyChain

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        setContent {
            FirezoneTheme {
                CertificatePermissionScreen(
                    onSelectCertificate = ::chooseCertificate,
                    onSkip = ::finish,
                )
            }
        }
    }

    private fun chooseCertificate() {
        val configuredAlias = repository.getX509CertificateAliasSync(applicationRestrictions)

        // Android answers on a binder thread, so anything touching the UI hops back itself.
        keyChain.choosePrivateKeyAlias(this, requestUri(), configuredAlias) { alias ->
            // KeyChain takes the configured alias as a pre-selection only, so the user can
            // hand back a different one, which leaves the configured certificate still refused.
            if (alias != null && alias == configuredAlias) {
                finish()
            } else {
                runOnUiThread {
                    Toast
                        .makeText(this, R.string.device_trust_no_certificate_selected, Toast.LENGTH_LONG)
                        .show()
                }
            }
        }
    }

    /** The portal the certificate is meant for, shown by Android in the chooser dialog. */
    private fun requestUri(): Uri? = runCatching { Uri.parse(repository.getConfigSync().apiUrl) }.getOrNull()
}
