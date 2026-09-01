// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core.x509

import android.app.Activity
import android.content.Context
import android.net.Uri
import java.security.PrivateKey
import java.security.cert.X509Certificate
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
}
