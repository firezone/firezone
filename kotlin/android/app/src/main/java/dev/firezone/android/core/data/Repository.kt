// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.core.data

import android.content.Context
import android.content.SharedPreferences
import android.os.Bundle
import com.google.gson.Gson
import com.google.gson.annotations.SerializedName
import com.google.gson.reflect.TypeToken
import dev.firezone.android.BuildConfig
import dev.firezone.android.core.data.model.Config
import dev.firezone.android.core.data.model.ManagedConfigStatus
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

class Repository
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

        fun getConfigSync(): Config =
            {
                val authURL =
                    sharedPreferences.getString(MANAGED_AUTH_URL_KEY, null)
                        ?: sharedPreferences.getString(AUTH_URL_KEY, null)
                        ?: BuildConfig.AUTH_URL

                val apiURL =
                    sharedPreferences.getString(MANAGED_API_URL_KEY, null)
                        ?: sharedPreferences.getString(API_URL_KEY, null)
                        ?: BuildConfig.API_URL

                val logFilter =
                    sharedPreferences.getString(MANAGED_LOG_FILTER_KEY, null)
                        ?: sharedPreferences.getString(LOG_FILTER_KEY, null)
                        ?: BuildConfig.LOG_FILTER

                val accountSlug =
                    sharedPreferences.getString(MANAGED_ACCOUNT_SLUG_KEY, null)
                        ?: sharedPreferences.getString(ACCOUNT_SLUG_KEY, null)
                        ?: ""

                val startOnLogin =
                    if (sharedPreferences.contains(MANAGED_START_ON_LOGIN_KEY)) {
                        sharedPreferences.getBoolean(MANAGED_START_ON_LOGIN_KEY, false)
                    } else {
                        sharedPreferences.getBoolean(START_ON_LOGIN_KEY, false)
                    }

                val connectOnStart =
                    if (sharedPreferences.contains(MANAGED_CONNECT_ON_START_KEY)) {
                        sharedPreferences.getBoolean(MANAGED_CONNECT_ON_START_KEY, false)
                    } else {
                        sharedPreferences.getBoolean(CONNECT_ON_START_KEY, false)
                    }

                Config(
                    authUrl = authURL,
                    apiUrl = apiURL,
                    logFilter = logFilter,
                    accountSlug = accountSlug,
                    startOnLogin = startOnLogin,
                    connectOnStart = connectOnStart,
                )
            }()

        fun getConfig(): Flow<Config> =
            flow {
                emit(getConfigSync())
            }.flowOn(coroutineDispatcher)

        fun getDefaultConfigSync(): Config =
            Config(
                BuildConfig.AUTH_URL,
                BuildConfig.API_URL,
                BuildConfig.LOG_FILTER,
                accountSlug = "",
                startOnLogin = false,
                connectOnStart = false,
            )

        fun getDefaultConfig(): Flow<Config> =
            flow {
                emit(getDefaultConfigSync())
            }.flowOn(coroutineDispatcher)

        fun saveSettings(value: Config): Flow<Unit> =
            flow {
                emit(
                    sharedPreferences
                        .edit()
                        .putString(AUTH_URL_KEY, value.authUrl)
                        .putString(API_URL_KEY, value.apiUrl)
                        .putString(LOG_FILTER_KEY, value.logFilter)
                        .putString(ACCOUNT_SLUG_KEY, value.accountSlug)
                        .putBoolean(START_ON_LOGIN_KEY, value.startOnLogin)
                        .putBoolean(CONNECT_ON_START_KEY, value.connectOnStart)
                        .apply(),
                )
            }.flowOn(coroutineDispatcher)

        // TODO: Consider adding support for the legacy managed configuration keys like token,
        //  allowedApplications, etc from pilot customer.
        fun saveManagedConfiguration(bundle: Bundle): Flow<Unit> =
            flow {
                val editor = sharedPreferences.edit()

                if (bundle.containsKey(AUTH_URL_KEY)) {
                    editor.putString(MANAGED_AUTH_URL_KEY, bundle.getString(AUTH_URL_KEY))
                }
                if (bundle.containsKey(API_URL_KEY)) {
                    editor.putString(MANAGED_API_URL_KEY, bundle.getString(API_URL_KEY))
                }
                if (bundle.containsKey(LOG_FILTER_KEY)) {
                    editor.putString(MANAGED_LOG_FILTER_KEY, bundle.getString(LOG_FILTER_KEY))
                }
                if (bundle.containsKey(ACCOUNT_SLUG_KEY)) {
                    editor.putString(MANAGED_ACCOUNT_SLUG_KEY, bundle.getString(ACCOUNT_SLUG_KEY))
                }
                if (bundle.containsKey(START_ON_LOGIN_KEY)) {
                    editor.putBoolean(MANAGED_START_ON_LOGIN_KEY, bundle.getBoolean(START_ON_LOGIN_KEY, false))
                }
                if (bundle.containsKey(CONNECT_ON_START_KEY)) {
                    editor.putBoolean(MANAGED_CONNECT_ON_START_KEY, bundle.getBoolean(CONNECT_ON_START_KEY, false))
                }

                emit(editor.apply())
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

        fun getAccountSlug(): Flow<String?> =
            flow {
                emit(sharedPreferences.getString(ACCOUNT_SLUG_KEY, null))
            }.flowOn(coroutineDispatcher)

        fun getActorName(): Flow<String?> =
            flow {
                emit(getActorNameSync())
            }.flowOn(coroutineDispatcher)

        fun getActorNameSync(): String? =
            sharedPreferences.getString(ACTOR_NAME_KEY, null)?.let {
                if (it.isNotEmpty()) "Signed in as $it" else "Signed in"
            }

        fun getNonceSync(): String? = sharedPreferences.getString(NONCE_KEY, null)

        fun saveAccountSlug(value: String): Flow<Unit> =
            flow {
                emit(
                    sharedPreferences
                        .edit()
                        .putString(ACCOUNT_SLUG_KEY, value)
                        .apply(),
                )
            }.flowOn(coroutineDispatcher)

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

        fun getManagedStatus(): ManagedConfigStatus =
            ManagedConfigStatus(
                isAuthUrlManaged = isAuthUrlManaged(),
                isApiUrlManaged = isApiUrlManaged(),
                isLogFilterManaged = isLogFilterManaged(),
                isAccountSlugManaged = isAccountSlugManaged(),
                isStartOnLoginManaged = isStartOnLoginManaged(),
                isConnectOnStartManaged = isConnectOnStartManaged(),
            )

        fun isAuthUrlManaged(): Boolean = sharedPreferences.contains(MANAGED_AUTH_URL_KEY)

        fun isApiUrlManaged(): Boolean = sharedPreferences.contains(MANAGED_API_URL_KEY)

        fun isLogFilterManaged(): Boolean = sharedPreferences.contains(MANAGED_LOG_FILTER_KEY)

        fun isAccountSlugManaged(): Boolean = sharedPreferences.contains(MANAGED_ACCOUNT_SLUG_KEY)

        fun isStartOnLoginManaged(): Boolean = sharedPreferences.contains(MANAGED_START_ON_LOGIN_KEY)

        fun isConnectOnStartManaged(): Boolean = sharedPreferences.contains(MANAGED_CONNECT_ON_START_KEY)

        companion object {
            private const val AUTH_URL_KEY = "authUrl"
            private const val ACTOR_NAME_KEY = "actorName"
            private const val API_URL_KEY = "apiUrl"
            private const val FAVORITE_RESOURCES_KEY = "favoriteResources"
            private const val LOG_FILTER_KEY = "logFilter"
            private const val ACCOUNT_SLUG_KEY = "accountSlug"
            private const val START_ON_LOGIN_KEY = "startOnLogin"
            private const val CONNECT_ON_START_KEY = "connectOnStart"
            private const val MANAGED_AUTH_URL_KEY = "managedAuthUrl"
            private const val MANAGED_API_URL_KEY = "managedApiUrl"
            private const val MANAGED_LOG_FILTER_KEY = "managedLogFilter"
            private const val MANAGED_ACCOUNT_SLUG_KEY = "managedAccountSlug"
            private const val MANAGED_START_ON_LOGIN_KEY = "managedStartOnLogin"
            private const val MANAGED_CONNECT_ON_START_KEY = "managedConnectOnStart"
            private const val TOKEN_KEY = "token"
            private const val NONCE_KEY = "nonce"
            private const val STATE_KEY = "state"
            private const val DEVICE_ID_KEY = "deviceId"
            private const val ENABLED_INTERNET_RESOURCE_KEY = "enabledInternetResource"
        }
    }
