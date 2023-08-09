package dev.firezone.android.core.data

import dev.firezone.android.core.data.model.Config
import kotlinx.coroutines.flow.Flow

internal interface PreferenceRepository {
    fun getConfig(): Flow<Config>

    fun savePortalUrl(portalUrl: String): Flow<Unit>

    fun saveJWT(jwt: String): Flow<Unit>

    fun validateCsrfToken(value: String): Flow<Boolean>
}
