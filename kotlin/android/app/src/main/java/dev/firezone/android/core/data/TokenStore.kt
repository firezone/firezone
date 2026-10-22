// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core.data

import android.content.SharedPreferences
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

        fun save(value: String) {
            sharedPreferences.edit().putString(TOKEN_KEY, value).apply()
        }

        fun clear() {
            sharedPreferences.edit().remove(TOKEN_KEY).apply()
        }

        private companion object {
            const val TOKEN_KEY = "token"
            const val LEGACY_NONCE_KEY = "nonce"
            const val LEGACY_STATE_KEY = "state"
            const val LEGACY_PENDING_AUTH_HANDOFF_STATE_HASH_KEY = "pendingAuthHandoffStateHash"
        }
    }
