// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.auth

import android.net.Uri
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.data.TokenStore
import dev.firezone.android.core.data.model.ControlPlane
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
            if (outcome !is AuthCallbackOutcome.Success) {
                return outcome
            }

            val controlPlane =
                when (uri?.getQueryParameter("region")) {
                    "us" -> ControlPlane.CLOUD_US
                    "eu" -> ControlPlane.CLOUD_EU
                    else -> null
                }
            val signedInWith =
                if (controlPlane != null) {
                    repo.saveSettingsSync(
                        repo.getConfigSync().copy(
                            authUrl = checkNotNull(controlPlane.authUrl),
                            apiUrl = checkNotNull(controlPlane.apiUrl),
                        ),
                    )
                    val config = repo.getConfigSync()
                    outcome.signedInWith.copy(authUrl = config.authUrl, apiUrl = config.apiUrl)
                } else {
                    outcome.signedInWith
                }

            repo.saveActiveSignInSettingsSync(signedInWith)
            tokenStore.save(outcome.token)

            return outcome.copy(signedInWith = signedInWith)
        }
    }
