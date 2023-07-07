package dev.firezone.android.features.applink.domain

import android.content.SharedPreferences
import dev.firezone.android.features.applink.data.AppLinkRepository
import dev.firezone.android.features.auth.data.AuthRepository
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import java.util.Base64
import javax.inject.Inject
import kotlin.random.Random

internal class AppLinkRepositoryImpl @Inject constructor(
    private val coroutineDispatcher: CoroutineDispatcher,
    private val sharedPreferences: SharedPreferences
) : AppLinkRepository {

    override fun saveJWT(value: String): Flow<Unit> = flow {
        emit(
            sharedPreferences
                .edit()
                .putString(JWT_KEY, value)
                .apply()
        )
    }.flowOn(coroutineDispatcher)

    override fun validateCsrfToken(value: String): Flow<Boolean> = flow {
        val token = sharedPreferences.getString(CSRF_KEY, "")
        emit(token == value)
    }.flowOn(coroutineDispatcher)

    companion object {
        private const val JWT_KEY = "jwt"
        private const val CSRF_KEY = "csrf"
    }
}
