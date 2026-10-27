// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.auth

import android.net.Uri
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.data.TokenStore
import dev.firezone.android.core.data.model.signInConfig
import javax.inject.Inject

internal class AuthCallbackHandler
    @Inject
    constructor(
        private val pendingAuthSession: PendingAuthSession,
        private val tokenStore: TokenStore,
        private val repo: Repository,
    ) {
        fun handle(uri: Uri?): AuthCallbackOutcome {
            val outcome = pendingAuthSession.complete(uri)
            if (outcome is AuthCallbackOutcome.Success) {
                tokenStore.save(outcome.token, repo.getConfigSync().signInConfig())
            }

            return outcome
        }
    }
