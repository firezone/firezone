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

    @Volatile
    private var userChoice: String? = null

    @Volatile
    private var policyAnswer: String? = null

    /** Files [identity] under [alias], granted to the app or merely installed. */
    fun install(
        alias: String,
        identity: TestIdentity,
        granted: Boolean,
    ) {
        entries[alias] = Entry(identity.chain, identity.privateKey, granted)
    }

    /** Has the user pick [alias] in the chooser instead of the one offered to them. */
    fun userChooses(alias: String) {
        userChoice = alias
    }

    /** Has the device policy answer [alias] when asked, granting it the way the real one does. */
    fun policyAnswers(alias: String) {
        policyAnswer = alias
    }

    fun reset() {
        entries.clear()
        userChoice = null
        policyAnswer = null
    }

    override fun certificateChain(alias: String): List<X509Certificate>? = entries[alias]?.takeIf { it.granted }?.chain

    override fun privateKey(alias: String): PrivateKey? = entries[alias]?.takeIf { it.granted }?.privateKey

    override fun choosePrivateKeyAlias(
        activity: Activity,
        requestUri: Uri?,
        preselectedAlias: String?,
        onChosen: (String?) -> Unit,
    ) {
        // The user takes the offered certificate unless the test scripted another pick, either
        // way only when the KeyChain holds it, and choosing is what grants it.
        val alias = (userChoice ?: preselectedAlias)?.takeIf(entries::containsKey)

        if (alias != null) {
            entries.computeIfPresent(alias) { _, entry -> entry.copy(granted = true) }
        }

        onChosen(alias)
    }

    override fun policyAlias(
        activity: Activity,
        requestUri: Uri?,
        onAnswer: (String?) -> Unit,
    ) {
        val alias = policyAnswer?.takeIf(entries::containsKey)

        if (alias != null) {
            entries.computeIfPresent(alias) { _, entry -> entry.copy(granted = true) }
        }

        onAnswer(alias)
    }
}
