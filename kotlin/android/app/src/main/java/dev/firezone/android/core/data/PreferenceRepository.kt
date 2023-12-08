/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.core.data

import dev.firezone.android.core.data.model.Config
import kotlinx.coroutines.flow.Flow

internal interface PreferenceRepository {
    fun getConfigSync(): Config

    fun getConfig(): Flow<Config>

    fun saveSettings(
        authBaseUrl: String,
        apiUrl: String,
        logFilter: String,
    ): Flow<Unit>

    fun saveToken(value: String): Flow<Unit>

    fun validateCsrfToken(value: String): Flow<Boolean>

    fun clearToken()

    fun clearAll()
}
