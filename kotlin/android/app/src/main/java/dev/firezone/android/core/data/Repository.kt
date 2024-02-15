/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.core.data

import dev.firezone.android.core.data.model.Config
import kotlinx.coroutines.flow.Flow

interface Repository {
    fun getConfigSync(): Config

    fun getConfig(): Flow<Config>

    fun getDefaultConfigSync(): Config

    fun getDefaultConfig(): Flow<Config>

    fun saveSettings(
        authBaseUrl: String,
        apiUrl: String,
        logFilter: String,
    ): Flow<Unit>

    fun saveDeviceIdSync(value: String): Unit

    fun getToken(): Flow<String?>

    fun getTokenSync(): String?

    fun getStateSync(): String?

    fun getNonceSync(): String?

    fun getDeviceIdSync(): String?

    fun getActorName(): Flow<String?>

    fun getActorNameSync(): String?

    fun saveNonce(value: String): Flow<Unit>

    fun saveState(value: String): Flow<Unit>

    fun saveStateSync(value: String): Unit

    fun saveNonceSync(value: String): Unit

    fun saveToken(value: String): Flow<Unit>

    fun saveActorName(value: String): Flow<Unit>

    fun validateState(value: String): Flow<Boolean>

    fun clearToken()

    fun clearNonce()

    fun clearState()

    fun clearActorName()
}
