// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.e2e

import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.data.TokenStore
import dev.firezone.android.core.data.model.signInConfig

/** Stores `token` the way `AuthCallbackHandler` does after a sign-in. */
internal fun TokenStore.signIn(
    token: String,
    repo: Repository,
) = save(token, repo.getConfigSync().signInConfig())
