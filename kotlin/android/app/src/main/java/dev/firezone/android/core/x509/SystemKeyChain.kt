// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core.x509

import android.app.Activity
import android.app.admin.DevicePolicyManager
import android.content.Context
import android.net.Uri
import android.os.Build
import java.security.PrivateKey
import java.security.cert.X509Certificate
import javax.security.auth.x500.X500Principal
import android.security.KeyChain as AndroidKeyChain

/**
 * The real system KeyChain.
 *
 * The reads block on the KeyChain system service, so callers stay off the main thread.
 */
class SystemKeyChain(
    private val context: Context,
) : KeyChain {
    override fun certificateChain(alias: String): List<X509Certificate>? = AndroidKeyChain.getCertificateChain(context, alias)?.toList()

    override fun privateKey(alias: String): PrivateKey? = AndroidKeyChain.getPrivateKey(context, alias)

    override fun choosePrivateKeyAlias(
        activity: Activity,
        requestUri: Uri?,
        preselectedAlias: String?,
        onChosen: (String?) -> Unit,
    ) {
        AndroidKeyChain.choosePrivateKeyAlias(
            activity,
            onChosen,
            arrayOf("RSA", "EC"),
            null,
            requestUri,
            preselectedAlias,
        )
    }

    override fun policyAlias(
        activity: Activity,
        requestUri: Uri?,
        onAnswer: (String?) -> Unit,
    ) {
        // Before Android 10 the chooser ignores the issuer filter and puts up a dialog even over an
        // empty list, so there is no quiet way to ask.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            onAnswer(null)

            return
        }

        // Only an owner can answer, so a device without one is not worth the Activity round trip.
        val activeAdmins = context.getSystemService(DevicePolicyManager::class.java)?.activeAdmins

        if (activeAdmins.isNullOrEmpty()) {
            onAnswer(null)

            return
        }

        // The policy is asked before the chooser filters what is installed, and an issuer nothing was
        // issued by leaves that filter empty, which Android takes as a reason to show nothing.
        AndroidKeyChain.choosePrivateKeyAlias(
            activity,
            onAnswer,
            arrayOf("RSA", "EC"),
            arrayOf(NO_ISSUER),
            requestUri,
            null,
        )
    }

    private companion object {
        private val NO_ISSUER = X500Principal("CN=Firezone policy probe")
    }
}
