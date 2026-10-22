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

    /**
     * Android has no call that asks the policy alone, so this bends the chooser into one.
     *
     * `KeyChain.choosePrivateKeyAlias` runs two stages. First it asks the device or profile owner
     * for an alias; an answer is granted and returned as is, with the filter arguments never
     * consulted. Only when the owner names nothing does it list the installed certificates for
     * the user, and that list is what [keyTypes][AndroidKeyChain.choosePrivateKeyAlias] and
     * `issuers` narrow down. Since Android 10 an empty list finishes with `null` instead of a
     * dialog, as the documentation of `choosePrivateKeyAlias` promises.
     *
     * So the issuer passed here is not what we are looking for. It is a name no certificate was
     * issued by, which empties the second stage and leaves only the first: the policy's answer,
     * or `null`, and in neither case anything on screen. Filtering for a matching issuer would do
     * the opposite, since a match is shown to the user and returned only after they tap Allow.
     */
    override fun policyAlias(
        activity: Activity,
        requestUri: Uri?,
        onAnswer: (String?) -> Unit,
    ) {
        // Before Android 10 the second stage ignores the filter and puts up a dialog even over an
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

        AndroidKeyChain.choosePrivateKeyAlias(
            activity,
            onAnswer,
            arrayOf("RSA", "EC"),
            arrayOf(UNMATCHABLE_ISSUER),
            requestUri,
            null,
        )
    }

    private companion object {
        private val UNMATCHABLE_ISSUER = X500Principal("CN=Firezone policy probe")
    }
}
