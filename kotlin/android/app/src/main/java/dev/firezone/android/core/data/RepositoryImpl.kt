/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.core.data

import android.content.Context
import android.content.SharedPreferences
import android.os.Bundle
import dev.firezone.android.BuildConfig
import dev.firezone.android.core.data.model.Config
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import java.security.MessageDigest
import javax.inject.Inject

internal class RepositoryImpl
    @Inject
    constructor(
        private val context: Context,
        private val coroutineDispatcher: CoroutineDispatcher,
        private val sharedPreferences: SharedPreferences,
        private val appRestrictions: Bundle,
    ) : Repository {
        override fun getConfigSync(): Config {
            return Config(
                sharedPreferences.getString(AUTH_BASE_URL_KEY, null)
                    ?: BuildConfig.AUTH_BASE_URL,
                sharedPreferences.getString(API_URL_KEY, null)
                    ?: BuildConfig.API_URL,
                sharedPreferences.getString(LOG_FILTER_KEY, null)
                    ?: BuildConfig.LOG_FILTER,
            )
        }

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

        override fun getDeviceIdSync(): String? = sharedPreferences.getString(DEVICE_ID_KEY, null)

        override fun getToken(): Flow<String?> =
            flow {
                emit(
                    appRestrictions.getString(TOKEN_KEY, null)
                        ?: sharedPreferences.getString(TOKEN_KEY, null),
                )
            }.flowOn(coroutineDispatcher)

        override fun getTokenSync(): String? =
            appRestrictions.getString(TOKEN_KEY, null)
                ?: sharedPreferences.getString(TOKEN_KEY, null)

        override fun getStateSync(): String? = sharedPreferences.getString(STATE_KEY, null)

        override fun getActorName(): Flow<String?> =
            flow {
                emit(getActorNameSync())
            }.flowOn(coroutineDispatcher)

        override fun getActorNameSync(): String? =
            sharedPreferences.getString(ACTOR_NAME_KEY, null)?.let {
                if (it.isNotEmpty()) "Signed in as $it" else "Signed in"
            }

        override fun getNonceSync(): String? = sharedPreferences.getString(NONCE_KEY, null)

        override fun saveDeviceIdSync(value: String): Unit =
            sharedPreferences
                .edit()
                .putString(DEVICE_ID_KEY, value)
                .apply()

        override fun saveNonce(value: String): Flow<Unit> =
            flow {
                emit(saveNonceSync(value))
            }.flowOn(coroutineDispatcher)

        override fun saveNonceSync(value: String) = sharedPreferences.edit().putString(NONCE_KEY, value).apply()

        override fun saveState(value: String): Flow<Unit> =
            flow {
                emit(saveStateSync(value))
            }.flowOn(coroutineDispatcher)

        override fun saveStateSync(value: String) = sharedPreferences.edit().putString(STATE_KEY, value).apply()

        override fun saveToken(value: String): Flow<Unit> =
            flow {
                val nonce = sharedPreferences.getString(NONCE_KEY, "").orEmpty()
                emit(
                    sharedPreferences
                        .edit()
                        .putString(TOKEN_KEY, nonce.plus(value))
                        .apply(),
                )
            }.flowOn(coroutineDispatcher)

        override fun saveActorName(value: String): Flow<Unit> =
            flow {
                emit(
                    sharedPreferences
                        .edit()
                        .putString(ACTOR_NAME_KEY, value)
                        .apply(),
                )
            }.flowOn(coroutineDispatcher)

        override fun validateState(value: String): Flow<Boolean> =
            flow {
                val state = sharedPreferences.getString(STATE_KEY, "").orEmpty()
                emit(MessageDigest.isEqual(state.toByteArray(), value.toByteArray()))
            }.flowOn(coroutineDispatcher)

        override fun clearToken() {
            sharedPreferences.edit().apply {
                remove(TOKEN_KEY)
                apply()
            }
        }

        override fun clearNonce() {
            sharedPreferences.edit().apply {
                remove(NONCE_KEY)
                apply()
            }
        }

        override fun clearState() {
            sharedPreferences.edit().apply {
                remove(STATE_KEY)
                apply()
            }
        }

        override fun clearActorName() {
            sharedPreferences.edit().apply {
                remove(ACTOR_NAME_KEY)
                apply()
            }
        }

        companion object {
            private const val AUTH_BASE_URL_KEY = "authBaseUrl"
            private const val ACTOR_NAME_KEY = "actorName"
            private const val API_URL_KEY = "apiUrl"
            private const val LOG_FILTER_KEY = "logFilter"
            private const val TOKEN_KEY = "token"
            private const val NONCE_KEY = "nonce"
            private const val STATE_KEY = "state"
            private const val DEVICE_ID_KEY = "deviceId"
        }
    }
