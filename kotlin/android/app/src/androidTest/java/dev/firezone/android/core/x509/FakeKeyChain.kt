// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core.x509

import android.app.Activity
import android.net.Uri
import java.security.PrivateKey
import java.security.cert.X509Certificate
import java.util.concurrent.ConcurrentHashMap

/**
 * Stands in for the system KeyChain, holding whatever a test installs.
 *
 * `ManagedKeyChainTest` pins the real KeyChain to the behaviour faked here: a withheld alias and
 * an absent one both read as `null`, and choosing grants the alias for good. Process-wide for the
 * same reason as the session factory: the service reading it may outlive the test's object graph.
 */
object FakeKeyChain : KeyChain {
    private data class Entry(
        val chain: List<X509Certificate>,
        val privateKey: PrivateKey,
        val granted: Boolean,
    )

    private val entries = ConcurrentHashMap<String, Entry>()

    /** Files [identity] under [alias], granted to the app or merely installed. */
    fun install(
        alias: String,
        identity: TestIdentity,
        granted: Boolean,
    ) {
        entries[alias] = Entry(identity.chain, identity.privateKey, granted)
    }

    fun reset() {
        entries.clear()
    }

    override fun certificateChain(alias: String): List<X509Certificate>? = entries[alias]?.takeIf { it.granted }?.chain

    override fun privateKey(alias: String): PrivateKey? = entries[alias]?.takeIf { it.granted }?.privateKey

    override fun choosePrivateKeyAlias(
        activity: Activity,
        requestUri: Uri?,
        preselectedAlias: String?,
        onChosen: (String?) -> Unit,
    ) {
        // The user takes the offered certificate when the KeyChain holds it, and choosing is
        // what grants it.
        val entry = preselectedAlias?.let { alias -> entries[alias] }

        if (entry != null) {
            entries[preselectedAlias] = entry.copy(granted = true)
        }

        onChosen(preselectedAlias.takeIf { entry != null })
    }
}
