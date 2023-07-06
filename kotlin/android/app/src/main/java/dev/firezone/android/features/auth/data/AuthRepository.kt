package dev.firezone.android.features.auth.data

import kotlinx.coroutines.flow.Flow

internal interface AuthRepository {

    fun generateCsrfToken(): Flow<String>
}
