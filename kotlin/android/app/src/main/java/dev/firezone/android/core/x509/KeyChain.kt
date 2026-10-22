// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core.x509

import android.app.Activity
import android.net.Uri
import java.security.PrivateKey
import java.security.cert.X509Certificate

/**
 * What Firezone asks of the system KeyChain, so tests can script its answers.
 *
 * The KeyChain granting us an alias is the user's or the administrator's decision, which is why
 * every reader has to cope with `null`: an alias that does not exist and one we were not granted
 * are indistinguishable by design.
 */
interface KeyChain {
    /** The certificate chain filed under [alias], or `null` when the KeyChain withholds it. */
    fun certificateChain(alias: String): List<X509Certificate>?

    /** The private key filed under [alias], or `null` when the KeyChain withholds it. */
    fun privateKey(alias: String): PrivateKey?

    /**
     * Opens the system certificate chooser over [activity] and hands [onChosen] the picked alias,
     * or `null` when the user declined. Choosing grants us the alias, and the KeyChain remembers
     * the grant.
     *
     * [onChosen] is called on a binder thread, so anything touching the UI has to hop back itself.
     */
    fun choosePrivateKeyAlias(
        activity: Activity,
        requestUri: Uri?,
        preselectedAlias: String?,
        onChosen: (String?) -> Unit,
    )

    /**
     * Asks the device policy which alias Firezone should present, without ever showing the chooser.
     *
     * A device or profile owner may answer the chooser on the user's behalf, which is how an
     * administrator hands over a certificate whose alias never made it into our configuration. Where
     * no policy answers, [onAnswer] gets `null` and nothing was shown. Like choosing, an answer
     * arrives granted.
     *
     * [onAnswer] is called on a binder thread.
     */
    fun policyAlias(
        activity: Activity,
        requestUri: Uri?,
        onAnswer: (String?) -> Unit,
    )
}
