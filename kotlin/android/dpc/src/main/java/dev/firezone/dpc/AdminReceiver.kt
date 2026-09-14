// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.dpc

import android.app.admin.DeviceAdminReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri

class AdminReceiver : DeviceAdminReceiver() {
    /** Answers the KeyChain chooser with the alias a test set, or leaves the choice to the user. */
    override fun onChoosePrivateKeyAlias(
        context: Context,
        intent: Intent,
        uid: Int,
        uri: Uri?,
        alias: String?,
    ): String? = policyAlias(context)

    companion object {
        private const val POLICY_ALIAS = "privateKeyAlias"

        fun componentName(context: Context) = ComponentName(context, AdminReceiver::class.java)

        fun policyAlias(context: Context): String? = preferences(context).getString(POLICY_ALIAS, null)

        fun setPolicyAlias(
            context: Context,
            alias: String?,
        ) {
            preferences(context).edit().apply {
                if (alias == null) remove(POLICY_ALIAS) else putString(POLICY_ALIAS, alias)
                commit()
            }
        }

        private fun preferences(context: Context) = context.getSharedPreferences("policy", Context.MODE_PRIVATE)
    }
}
