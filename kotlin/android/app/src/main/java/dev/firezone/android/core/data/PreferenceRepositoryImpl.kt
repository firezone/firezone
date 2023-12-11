/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.core.data

import android.content.SharedPreferences
import dev.firezone.android.BuildConfig
import dev.firezone.android.core.data.model.Config
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import java.security.MessageDigest
import javax.inject.Inject

internal class PreferenceRepositoryImpl
    @Inject
    constructor(
        private val coroutineDispatcher: CoroutineDispatcher,
        private val sharedPreferences: SharedPreferences,
    ) : PreferenceRepository {
        override fun getConfigSync(): Config =
            Config(
                authBaseUrl = sharedPreferences.getString(AUTH_BASE_URL_KEY, null) ?: BuildConfig.AUTH_BASE_URL,
                apiUrl = sharedPreferences.getString(API_URL_KEY, null) ?: BuildConfig.API_URL,
                logFilter = sharedPreferences.getString(LOG_FILTER_KEY, null) ?: BuildConfig.LOG_FILTER,
                token = sharedPreferences.getString(TOKEN_KEY, null),
            )

        override fun getConfig(): Flow<Config> =
            flow {
                emit(getConfigSync())
            }.flowOn(coroutineDispatcher)

        override fun saveSettings(
            authBaseUrl: String,
            apiUrl: String,
            logFilter: String,
        ): Flow<Unit> =
            flow {
                emit(
                    sharedPreferences
                        .edit()
                        .putString(AUTH_BASE_URL_KEY, authBaseUrl)
                        .putString(API_URL_KEY, apiUrl)
                        .putString(LOG_FILTER_KEY, logFilter)
                        .apply(),
                )
            }.flowOn(coroutineDispatcher)

        override fun saveToken(value: String): Flow<Unit> =
            flow {
                emit(
                    sharedPreferences
                        .edit()
                        .putString(TOKEN_KEY, value)
                        .apply(),
                )
            }.flowOn(coroutineDispatcher)

        override fun validateCsrfToken(value: String): Flow<Boolean> =
            flow {
                val token = sharedPreferences.getString(CSRF_KEY, "").orEmpty()
                emit(MessageDigest.isEqual(token.toByteArray(), value.toByteArray()))
            }.flowOn(coroutineDispatcher)

        override fun clearToken() {
            sharedPreferences.edit().apply {
                remove(CSRF_KEY)
                remove(TOKEN_KEY)
                apply()
            }
        }

        override fun clearAll() {
            sharedPreferences.edit().clear().apply()
        }

        companion object {
            private const val AUTH_BASE_URL_KEY = "authBaseUrl"
            private const val API_URL_KEY = "apiUrl"
            private const val LOG_FILTER_KEY = "logFilter"
            private const val TOKEN_KEY = "token"
            private const val CSRF_KEY = "csrf"
        }
    }
