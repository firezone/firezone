package dev.firezone.android.core.data

import dev.firezone.android.core.data.model.Config
import kotlinx.coroutines.flow.Flow

internal interface PreferenceRepository {
    fun getConfigSync(): Config

    fun getConfig(): Flow<Config>

    fun saveAccountId(value: String): Flow<Unit>

    fun saveToken(value: String): Flow<Unit>

    fun saveIsConnectedSync(value: Boolean)

    fun saveIsConnected(value: Boolean): Flow<Unit>

    fun validateCsrfToken(value: String): Flow<Boolean>
}
