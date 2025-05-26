/* Licensed under Apache 2.0 (C) 2024 Firezone, Inc. */
package dev.firezone.android.core.data

import android.content.Context
import android.content.SharedPreferences
import com.google.gson.Gson
import com.google.gson.annotations.SerializedName
import com.google.gson.reflect.TypeToken
import dev.firezone.android.BuildConfig
import dev.firezone.android.core.data.model.UserConfig
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import java.security.MessageDigest
import javax.inject.Inject

const val ON_SYMBOL: String = "<->"
const val OFF_SYMBOL: String = " — "

enum class ResourceState {
    @SerializedName("enabled")
    ENABLED,

    @SerializedName("disabled")
    DISABLED,

    @SerializedName("unset")
    UNSET,
}

fun ResourceState.isEnabled(): Boolean = this == ResourceState.ENABLED

fun ResourceState.stateSymbol(): String =
    if (this.isEnabled()) {
        ON_SYMBOL
    } else {
        OFF_SYMBOL
    }

fun ResourceState.toggle(): ResourceState =
    if (this.isEnabled()) {
        ResourceState.DISABLED
    } else {
        ResourceState.ENABLED
    }

// Wrapper class used because `MutableStateFlow` will not
// notify subscribers if you submit the same object that's already in it.
class Favorites(
    val inner: HashSet<String>,
)

internal class Repository
    @Inject
    constructor(
        private val context: Context,
        private val coroutineDispatcher: CoroutineDispatcher,
        private val sharedPreferences: SharedPreferences,
    ) {
        // We are the only thing that can modify favorites so we shouldn't need to reload it after
        // this initial load
        // TODO: This should be immutable, we should just replace the hash set on every update
        private val _favorites =
            MutableStateFlow(Favorites(HashSet(sharedPreferences.getStringSet(FAVORITE_RESOURCES_KEY, null).orEmpty())))
        val favorites = _favorites.asStateFlow()

        fun getConfigSync(): UserConfig =
            UserConfig(
                sharedPreferences.getString(AUTH_URL_KEY, null)
                    ?: BuildConfig.AUTH_URL,
                sharedPreferences.getString(API_URL_KEY, null)
                    ?: BuildConfig.API_URL,
                sharedPreferences.getString(LOG_FILTER_KEY, null)
                    ?: BuildConfig.LOG_FILTER,
                connectOnStart = sharedPreferences.getBoolean(CONNECT_ON_START_KEY, false),
            )

        fun getConfig(): Flow<UserConfig> =
            flow {
                emit(getConfigSync())
            }.flowOn(coroutineDispatcher)

        fun getDefaultConfigSync(): UserConfig =
            UserConfig(
                BuildConfig.AUTH_URL,
                BuildConfig.API_URL,
                BuildConfig.LOG_FILTER,
                connectOnStart = false,
            )

        fun getDefaultConfig(): Flow<UserConfig> =
            flow {
                emit(getDefaultConfigSync())
            }.flowOn(coroutineDispatcher)

        fun saveSettings(value: UserConfig): Flow<Unit> =
            flow {
                emit(
                    sharedPreferences
                        .edit()
                        .putString(AUTH_URL_KEY, value.authUrl)
                        .putString(API_URL_KEY, value.apiUrl)
                        .putString(LOG_FILTER_KEY, value.logFilter)
                        .putBoolean(CONNECT_ON_START_KEY, value.connectOnStart)
                        .apply(),
                )
            }.flowOn(coroutineDispatcher)

        fun getDeviceIdSync(): String? = sharedPreferences.getString(DEVICE_ID_KEY, null)

        private fun saveFavoritesSync() {
            sharedPreferences.edit().putStringSet(FAVORITE_RESOURCES_KEY, favorites.value.inner).apply()
            _favorites.value = Favorites(favorites.value.inner)
        }

        fun addFavoriteResource(id: String) {
            favorites.value.inner.add(id)
            saveFavoritesSync()
        }

        fun removeFavoriteResource(id: String) {
            favorites.value.inner.remove(id)
            saveFavoritesSync()
        }

        fun resetFavorites() {
            favorites.value.inner.clear()
            saveFavoritesSync()
        }

        fun getToken(): Flow<String?> =
            flow {
                emit(sharedPreferences.getString(TOKEN_KEY, null))
            }.flowOn(coroutineDispatcher)

        fun getTokenSync(): String? = sharedPreferences.getString(TOKEN_KEY, null)

        fun getStateSync(): String? = sharedPreferences.getString(STATE_KEY, null)

        fun getActorName(): Flow<String?> =
            flow {
                emit(getActorNameSync())
            }.flowOn(coroutineDispatcher)

        fun getActorNameSync(): String? =
            sharedPreferences.getString(ACTOR_NAME_KEY, null)?.let {
                if (it.isNotEmpty()) "Signed in as $it" else "Signed in"
            }

        fun getNonceSync(): String? = sharedPreferences.getString(NONCE_KEY, null)

        fun saveDeviceIdSync(value: String): Unit =
            sharedPreferences
                .edit()
                .putString(DEVICE_ID_KEY, value)
                .apply()

        fun getInternetResourceStateSync(): ResourceState {
            val jsonString = sharedPreferences.getString(ENABLED_INTERNET_RESOURCE_KEY, null) ?: return ResourceState.UNSET
            val type = object : TypeToken<ResourceState>() {}.type
            return Gson().fromJson(jsonString, type)
        }

        fun saveInternetResourceStateSync(value: ResourceState): Unit =
            sharedPreferences
                .edit()
                .putString(ENABLED_INTERNET_RESOURCE_KEY, Gson().toJson(value))
                .apply()

        fun saveNonce(value: String): Flow<Unit> =
            flow {
                emit(saveNonceSync(value))
            }.flowOn(coroutineDispatcher)

        fun saveNonceSync(value: String) = sharedPreferences.edit().putString(NONCE_KEY, value).apply()

        fun saveState(value: String): Flow<Unit> =
            flow {
                emit(saveStateSync(value))
            }.flowOn(coroutineDispatcher)

        fun saveStateSync(value: String) = sharedPreferences.edit().putString(STATE_KEY, value).apply()

        fun saveToken(value: String): Flow<Unit> =
            flow {
                val nonce = sharedPreferences.getString(NONCE_KEY, "").orEmpty()
                emit(
                    sharedPreferences
                        .edit()
                        .putString(TOKEN_KEY, nonce.plus(value))
                        .apply(),
                )
            }.flowOn(coroutineDispatcher)

        fun saveActorName(value: String): Flow<Unit> =
            flow {
                emit(
                    sharedPreferences
                        .edit()
                        .putString(ACTOR_NAME_KEY, value)
                        .apply(),
                )
            }.flowOn(coroutineDispatcher)

        fun validateState(value: String): Flow<Boolean> =
            flow {
                val state = sharedPreferences.getString(STATE_KEY, "").orEmpty()
                emit(MessageDigest.isEqual(state.toByteArray(), value.toByteArray()))
            }.flowOn(coroutineDispatcher)

        fun clearToken() {
            sharedPreferences.edit().apply {
                remove(TOKEN_KEY)
                apply()
            }
        }

        fun clearNonce() {
            sharedPreferences.edit().apply {
                remove(NONCE_KEY)
                apply()
            }
        }

        fun clearState() {
            sharedPreferences.edit().apply {
                remove(STATE_KEY)
                apply()
            }
        }

        fun clearActorName() {
            sharedPreferences.edit().apply {
                remove(ACTOR_NAME_KEY)
                apply()
            }
        }

        companion object {
            private const val AUTH_URL_KEY = "authUrl"
            private const val ACTOR_NAME_KEY = "actorName"
            private const val API_URL_KEY = "apiUrl"
            private const val FAVORITE_RESOURCES_KEY = "favoriteResources"
            private const val LOG_FILTER_KEY = "logFilter"
            private const val CONNECT_ON_START_KEY = "connectOnStart"
            private const val TOKEN_KEY = "token"
            private const val NONCE_KEY = "nonce"
            private const val STATE_KEY = "state"
            private const val DEVICE_ID_KEY = "deviceId"
            private const val ENABLED_INTERNET_RESOURCE_KEY = "enabledInternetResource"
        }
    }
