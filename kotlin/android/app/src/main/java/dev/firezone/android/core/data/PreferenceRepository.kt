/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.core.data

import dev.firezone.android.core.data.model.Config
import kotlinx.coroutines.flow.Flow

interface PreferenceRepository {
    fun getConfigSync(): Config

    fun getConfig(): Flow<Config>

    fun saveSettings(
        authBaseUrl: String,
        apiUrl: String,
        logFilter: String,
    ): Flow<Unit>

    fun saveDeviceIdSync(value: String): Unit

    fun getDeviceIdSync(): String?

    fun saveToken(value: String): Flow<Unit>

    fun saveActorName(value: String): Flow<Unit>

    fun validateState(value: String): Flow<Boolean>

    fun clearToken()
}
