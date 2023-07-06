package dev.firezone.android.features.applink.data

import kotlinx.coroutines.flow.Flow

internal interface AppLinkRepository {

    fun saveJWT(value: String): Flow<Unit>

    fun validateCsrfToken(value: String): Flow<Boolean>
}
