/* Licensed under Apache 2.0 (C) 2024 Firezone, Inc. */
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
    fun getDeviceIdSync(): String?

    fun getFavorites(): Flow<HashSet<String>>
    fun saveFavorites(value: HashSet<String>): Flow<Unit>

    fun getToken(): Flow<String?>
    fun getTokenSync(): String?
    fun getStateSync(): String?
    fun saveToken(value: String): Flow<Unit>
    fun clearToken()

    fun getNonceSync(): String?
    fun saveNonce(value: String): Flow<Unit>
    fun saveNonceSync(value: String): Unit
    fun clearNonce()

    fun getActorName(): Flow<String?>
    fun getActorNameSync(): String?
    fun saveActorName(value: String): Flow<Unit>
    fun clearActorName()

    fun saveState(value: String): Flow<Unit>
    fun saveStateSync(value: String): Unit
    fun validateState(value: String): Flow<Boolean>
    fun clearState()
}
