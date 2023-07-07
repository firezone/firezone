package dev.firezone.android.features.signin.domain

import android.content.SharedPreferences
import dev.firezone.android.features.signin.data.SignInRepository
import javax.inject.Inject
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn

private const val AUTH_TOKEN_KEY = "authToken"

internal class SignInRepositoryImpl @Inject constructor(
    private val coroutineDispatcher: CoroutineDispatcher,
    private val sharedPreferences: SharedPreferences
) : SignInRepository {

    override fun saveAuthToken(): Flow<Unit> = flow {
        // TODO: Save auth token here?
        emit(
            sharedPreferences
                .edit()
                .putString(AUTH_TOKEN_KEY, "dummy-auth-token")
                .apply()
        )
    }.flowOn(coroutineDispatcher)
}
