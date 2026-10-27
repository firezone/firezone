// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core.data

import android.content.SharedPreferences
import dev.firezone.android.core.data.model.SignInConfig
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
internal class TokenStore
    @Inject
    constructor(
        private val sharedPreferences: SharedPreferences,
    ) {
        init {
            sharedPreferences
                .edit()
                .remove(LEGACY_NONCE_KEY)
                .remove(LEGACY_STATE_KEY)
                .remove(LEGACY_PENDING_AUTH_HANDOFF_STATE_HASH_KEY)
                .apply()
        }

        fun get(): String? = sharedPreferences.getString(TOKEN_KEY, null)

        fun save(
            value: String,
            signedInWith: SignInConfig,
        ) {
            sharedPreferences
                .edit()
                .putString(TOKEN_KEY, value)
                .putString(SIGNED_IN_ACCOUNT_SLUG_KEY, signedInWith.accountSlug)
                .putString(SIGNED_IN_AUTH_URL_KEY, signedInWith.authUrl)
                .putString(SIGNED_IN_API_URL_KEY, signedInWith.apiUrl)
                .apply()
        }

        fun signedInWith(): SignInConfig? {
            val accountSlug = sharedPreferences.getString(SIGNED_IN_ACCOUNT_SLUG_KEY, null) ?: return null
            val authUrl = sharedPreferences.getString(SIGNED_IN_AUTH_URL_KEY, null) ?: return null
            val apiUrl = sharedPreferences.getString(SIGNED_IN_API_URL_KEY, null) ?: return null

            return SignInConfig(accountSlug, authUrl, apiUrl)
        }

        fun clear() {
            sharedPreferences
                .edit()
                .remove(TOKEN_KEY)
                .remove(SIGNED_IN_ACCOUNT_SLUG_KEY)
                .remove(SIGNED_IN_AUTH_URL_KEY)
                .remove(SIGNED_IN_API_URL_KEY)
                .apply()
        }

        private companion object {
            const val TOKEN_KEY = "token"
            const val SIGNED_IN_ACCOUNT_SLUG_KEY = "signedInAccountSlug"
            const val SIGNED_IN_AUTH_URL_KEY = "signedInAuthUrl"
            const val SIGNED_IN_API_URL_KEY = "signedInApiUrl"
            const val LEGACY_NONCE_KEY = "nonce"
            const val LEGACY_STATE_KEY = "state"
            const val LEGACY_PENDING_AUTH_HANDOFF_STATE_HASH_KEY = "pendingAuthHandoffStateHash"
        }
    }
