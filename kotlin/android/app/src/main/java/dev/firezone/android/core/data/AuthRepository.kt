/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.core.data

import kotlinx.coroutines.flow.Flow

internal interface AuthRepository {
    fun generateNonce(key: String): Flow<String>
}
