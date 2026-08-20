// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.permission.certificate.ui

import android.net.Uri
import android.os.Bundle
import android.security.KeyChain
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.R
import dev.firezone.android.core.data.Repository
import dev.firezone.android.databinding.ActivityCertificatePermissionBinding
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
    private lateinit var binding: ActivityCertificatePermissionBinding

    @Inject
    lateinit var repository: Repository

    @Inject
    lateinit var applicationRestrictions: Bundle

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityCertificatePermissionBinding.inflate(layoutInflater)
        setContentView(binding.root)

        binding.btnSelect.setOnClickListener { chooseCertificate() }
        binding.btnSkip.setOnClickListener { finish() }
    }

    private fun chooseCertificate() {
        // Android answers on a binder thread, so anything touching the UI hops back itself.
        KeyChain.choosePrivateKeyAlias(
            this,
            { alias ->
                if (alias == null) {
                    runOnUiThread {
                        Toast
                            .makeText(this, R.string.x509_no_certificate_selected, Toast.LENGTH_LONG)
                            .show()
                    }
                } else {
                    finish()
                }
            },
            arrayOf("RSA", "EC"),
            null,
            requestUri(),
            repository.getX509CertificateAliasSync(applicationRestrictions),
        )
    }

    /** The portal the certificate is meant for, shown by Android in the chooser dialog. */
    private fun requestUri(): Uri? = runCatching { Uri.parse(repository.getConfigSync().apiUrl) }.getOrNull()
}
