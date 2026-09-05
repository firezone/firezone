// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.dpc

import android.app.admin.DevicePolicyManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.util.Base64
import java.io.ByteArrayInputStream
import java.security.KeyStore
import java.security.PrivateKey
import java.security.cert.Certificate

/**
 * Puts a device into the states an X.509-managed device can be in, driven entirely by
 * `am broadcast` so that a test can provision without a human at the screen.
 *
 * Installing a key pair and setting managed configuration are owner-only APIs that no `adb`
 * command exposes, which is the only reason a Device Policy Controller has to exist here at all.
 * The result is reported back through the broadcast's result data, so the caller reads it from
 * `am broadcast` rather than from logcat.
 */
class ProvisionReceiver : BroadcastReceiver() {
    override fun onReceive(
        context: Context,
        intent: Intent,
    ) {
        val policy = context.getSystemService(DevicePolicyManager::class.java)
        val admin = AdminReceiver.componentName(context)

        val outcome =
            runCatching {
                when (intent.action) {
                    INSTALL_KEY_PAIR -> installKeyPair(policy, admin, intent)
                    SET_RESTRICTIONS -> setRestrictions(policy, admin, intent)
                    SET_POLICY_ALIAS -> setPolicyAlias(context, intent)
                    else -> "unknown action: ${intent.action}"
                }
            }

        resultCode = if (outcome.isSuccess) 0 else 1
        resultData = outcome.getOrElse { "${it::class.java.simpleName}: ${it.message}" }
    }

    /**
     * Installs a key pair under an alias, granting it to a package only when asked.
     *
     * Withholding the grant is the state a personally-owned device with a work profile is in: the
     * alias exists, and the app still cannot get a key for it. Any earlier key pair under the alias
     * goes first, so that the state this leaves behind does not depend on the state it found.
     */
    private fun installKeyPair(
        policy: DevicePolicyManager,
        admin: android.content.ComponentName,
        intent: Intent,
    ): String {
        val alias = intent.requireString(ALIAS)
        val keyStore = KeyStore.getInstance("PKCS12")
        val password = intent.requireString(PASSWORD).toCharArray()

        keyStore.load(ByteArrayInputStream(Base64.decode(intent.requireString(P12), Base64.DEFAULT)), password)

        val entryAlias =
            keyStore.aliases().toList().firstOrNull { keyStore.isKeyEntry(it) }
                ?: error("the PKCS#12 holds no key entry")
        val privateKey = keyStore.getKey(entryAlias, password) as PrivateKey
        val chain: Array<Certificate> = keyStore.getCertificateChain(entryAlias)

        policy.removeKeyPair(admin, alias)

        if (!policy.installKeyPair(admin, privateKey, chain, alias, false)) {
            error("installKeyPair refused alias '$alias'")
        }

        val grantTo = intent.getStringExtra(GRANT_TO)

        if (grantTo != null && !policy.grantKeyPairToApp(admin, alias, grantTo)) {
            error("grantKeyPairToApp refused '$grantTo'")
        }

        return "installed '$alias' (certificates=${chain.size}, granted=${grantTo ?: "nobody"})"
    }

    /** Sets one managed-configuration entry on a package, or clears its configuration entirely. */
    private fun setRestrictions(
        policy: DevicePolicyManager,
        admin: android.content.ComponentName,
        intent: Intent,
    ): String {
        val target = intent.requireString(PACKAGE)
        val key = intent.getStringExtra(KEY)
        val restrictions =
            Bundle().apply {
                if (key != null) putString(key, intent.requireString(VALUE))
            }

        policy.setApplicationRestrictions(admin, target, restrictions)

        return "set ${restrictions.keySet().joinToString().ifEmpty { "nothing" }} on $target"
    }

    /**
     * Sets the alias the DPC answers the KeyChain chooser with, or clears it.
     *
     * Answering is how an administrator hands an app a certificate silently, which is the state a
     * corporate-owned device with a certificate selection rule is in.
     */
    private fun setPolicyAlias(
        context: Context,
        intent: Intent,
    ): String {
        val alias = intent.getStringExtra(ALIAS)

        AdminReceiver.setPolicyAlias(context, alias)

        return "the chooser is answered with ${alias?.let { "'$it'" } ?: "nothing"}"
    }

    private fun Intent.requireString(name: String) = getStringExtra(name) ?: error("missing extra '$name'")

    private companion object {
        const val INSTALL_KEY_PAIR = "dev.firezone.dpc.INSTALL_KEY_PAIR"
        const val SET_RESTRICTIONS = "dev.firezone.dpc.SET_RESTRICTIONS"
        const val SET_POLICY_ALIAS = "dev.firezone.dpc.SET_POLICY_ALIAS"

        const val ALIAS = "alias"
        const val P12 = "p12"
        const val PASSWORD = "password"
        const val GRANT_TO = "grantTo"
        const val PACKAGE = "package"
        const val KEY = "key"
        const val VALUE = "value"
    }
}
