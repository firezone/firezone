package dev.firezone.android.features.signin.data

import kotlinx.coroutines.flow.Flow

internal interface SignInRepository {
    fun saveAuthToken(): Flow<Unit>
}
