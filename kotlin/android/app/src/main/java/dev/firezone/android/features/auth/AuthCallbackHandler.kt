// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.auth

import android.net.Uri
import dev.firezone.android.core.data.Repository
import kotlinx.coroutines.flow.first
import javax.inject.Inject

internal class AuthCallbackHandler
    @Inject
    constructor(
        private val pendingAuthSession: PendingAuthSession,
        private val repo: Repository,
    ) {
        suspend fun handle(uri: Uri?): AuthCallbackOutcome {
            val outcome = pendingAuthSession.complete(uri)
            if (outcome is AuthCallbackOutcome.Success) {
                repo.saveToken(outcome.token).first()
            }

            return outcome
        }
    }
