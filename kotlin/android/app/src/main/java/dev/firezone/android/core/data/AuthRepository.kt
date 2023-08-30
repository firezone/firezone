package dev.firezone.android.core.data

import kotlinx.coroutines.flow.Flow

internal interface AuthRepository {

    fun generateCsrfToken(): Flow<String>
}
