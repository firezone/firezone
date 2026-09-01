// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.core.data

import android.content.SharedPreferences
import android.os.Bundle
import com.google.gson.Gson
import com.google.gson.annotations.SerializedName
import com.google.gson.reflect.TypeToken
import dev.firezone.android.BuildConfig
import dev.firezone.android.core.data.model.Config
import dev.firezone.android.core.data.model.ManagedConfigStatus
import dev.firezone.android.core.data.model.ManagedConfiguration
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.withContext
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

enum class AuthCallbackResult {
    NEW_HANDOFF,
    PENDING_HANDOFF,
    INVALID,
}

class Repository
    @Inject
    constructor(
        private val coroutineDispatcher: CoroutineDispatcher,
        private val sharedPreferences: SharedPreferences,
    ) {
        // We are the only thing that can modify favorites so we shouldn't need to reload it after
        // this initial load
        // TODO: This should be immutable, we should just replace the hash set on every update
        private val _favorites =
            MutableStateFlow(Favorites(HashSet(sharedPreferences.getStringSet(FAVORITE_RESOURCES_KEY, null).orEmpty())))
        val favorites = _favorites.asStateFlow()
        private val authStateLock = Any()

        fun getConfigSync(): Config = getUserConfigSync().withManagedOverrides()

        fun getUserConfigSync(): Config {
            val defaults = getDefaultUserConfigSync()

            return Config(
                authUrl = sharedPreferences.getString(AUTH_URL_KEY, null) ?: defaults.authUrl,
                apiUrl = sharedPreferences.getString(API_URL_KEY, null) ?: defaults.apiUrl,
                logFilter = sharedPreferences.getString(LOG_FILTER_KEY, null) ?: defaults.logFilter,
                accountSlug = sharedPreferences.getString(ACCOUNT_SLUG_KEY, null) ?: defaults.accountSlug,
                startOnLogin = sharedPreferences.getBoolean(START_ON_LOGIN_KEY, defaults.startOnLogin),
                connectOnStart = sharedPreferences.getBoolean(CONNECT_ON_START_KEY, defaults.connectOnStart),
            )
        }

        internal fun getEffectiveConfig(
            userConfig: Config,
            managedConfiguration: ManagedConfiguration,
        ): Config = managedConfiguration.applyTo(userConfig)

        internal fun getEffectiveConfigFromPersistedManaged(userConfig: Config): Config = userConfig.withManagedOverrides()

        fun getDefaultUserConfigSync(): Config =
            Config(
                authUrl = BuildConfig.AUTH_URL,
                apiUrl = BuildConfig.API_URL,
                logFilter = BuildConfig.LOG_FILTER,
                accountSlug = "",
                startOnLogin = false,
                connectOnStart = false,
            )

        suspend fun saveUserConfig(value: Config) {
            withContext(coroutineDispatcher) { saveUserConfigSync(value) }
        }

        // TODO: Consider adding support for the legacy managed configuration keys like token,
        //  allowedApplications, etc from pilot customer.
        suspend fun saveManagedConfiguration(bundle: Bundle) {
            withContext(coroutineDispatcher) {
                val editor = sharedPreferences.edit()

                if (bundle.containsKey(AUTH_URL_KEY)) {
                    editor.putString(MANAGED_AUTH_URL_KEY, bundle.getString(AUTH_URL_KEY))
                } else {
                    editor.remove(MANAGED_AUTH_URL_KEY)
                }
                if (bundle.containsKey(API_URL_KEY)) {
                    editor.putString(MANAGED_API_URL_KEY, bundle.getString(API_URL_KEY))
                } else {
                    editor.remove(MANAGED_API_URL_KEY)
                }
                if (bundle.containsKey(LOG_FILTER_KEY)) {
                    editor.putString(MANAGED_LOG_FILTER_KEY, bundle.getString(LOG_FILTER_KEY))
                } else {
                    editor.remove(MANAGED_LOG_FILTER_KEY)
                }
                if (bundle.containsKey(ACCOUNT_SLUG_KEY)) {
                    editor.putString(MANAGED_ACCOUNT_SLUG_KEY, bundle.getString(ACCOUNT_SLUG_KEY))
                } else {
                    editor.remove(MANAGED_ACCOUNT_SLUG_KEY)
                }
                if (bundle.containsKey(START_ON_LOGIN_KEY)) {
                    editor.putBoolean(MANAGED_START_ON_LOGIN_KEY, bundle.getBoolean(START_ON_LOGIN_KEY, false))
                } else {
                    editor.remove(MANAGED_START_ON_LOGIN_KEY)
                }
                if (bundle.containsKey(CONNECT_ON_START_KEY)) {
                    editor.putBoolean(MANAGED_CONNECT_ON_START_KEY, bundle.getBoolean(CONNECT_ON_START_KEY, false))
                } else {
                    editor.remove(MANAGED_CONNECT_ON_START_KEY)
                }

                editor.apply()
            }
        }

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

        fun getTokenSync(): String? = sharedPreferences.getString(TOKEN_KEY, null)

        fun getStateSync(): String? = sharedPreferences.getString(STATE_KEY, null)

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

        fun saveNonceAndStateSync(
            nonce: String,
            state: String,
        ) {
            synchronized(authStateLock) {
                sharedPreferences
                    .edit()
                    .putString(NONCE_KEY, nonce)
                    .putString(STATE_KEY, state)
                    .remove(PENDING_AUTH_HANDOFF_STATE_HASH_KEY)
                    .apply()
            }
        }

        suspend fun saveAuthCallbackIfStateValid(
            state: String,
            fragment: String,
        ): AuthCallbackResult =
            withContext(coroutineDispatcher) {
                synchronized(authStateLock) {
                    val stateHash = hashAuthState(state)
                    val pendingStateHash = sharedPreferences.getString(PENDING_AUTH_HANDOFF_STATE_HASH_KEY, null)
                    val isPendingHandoff = constantTimeEquals(pendingStateHash, stateHash)
                    val expectedState = sharedPreferences.getString(STATE_KEY, "").orEmpty()
                    val isExpectedState = constantTimeEquals(expectedState, state)
                    when {
                        isPendingHandoff -> {
                            AuthCallbackResult.PENDING_HANDOFF
                        }

                        !isExpectedState -> {
                            AuthCallbackResult.INVALID
                        }

                        else -> {
                            val nonce = sharedPreferences.getString(NONCE_KEY, "").orEmpty()
                            sharedPreferences
                                .edit()
                                .putString(TOKEN_KEY, nonce.plus(fragment))
                                .remove(NONCE_KEY)
                                .remove(STATE_KEY)
                                .putString(PENDING_AUTH_HANDOFF_STATE_HASH_KEY, stateHash)
                                .apply()

                            AuthCallbackResult.NEW_HANDOFF
                        }
                    }
                }
            }

        fun acknowledgeAuthCallbackHandoff(state: String): Boolean =
            synchronized(authStateLock) {
                val stateHash = hashAuthState(state)
                val pendingStateHash = sharedPreferences.getString(PENDING_AUTH_HANDOFF_STATE_HASH_KEY, null)
                val isPendingHandoff = constantTimeEquals(pendingStateHash, stateHash)
                if (isPendingHandoff) {
                    sharedPreferences.edit().remove(PENDING_AUTH_HANDOFF_STATE_HASH_KEY).apply()
                }

                isPendingHandoff
            }

        fun clearToken() {
            synchronized(authStateLock) {
                sharedPreferences.edit().apply {
                    remove(TOKEN_KEY)
                    remove(PENDING_AUTH_HANDOFF_STATE_HASH_KEY)
                    apply()
                }
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

        private fun isAuthUrlManaged(): Boolean = sharedPreferences.contains(MANAGED_AUTH_URL_KEY)

        private fun isApiUrlManaged(): Boolean = sharedPreferences.contains(MANAGED_API_URL_KEY)

        private fun isLogFilterManaged(): Boolean = sharedPreferences.contains(MANAGED_LOG_FILTER_KEY)

        fun isAccountSlugManaged(): Boolean = sharedPreferences.contains(MANAGED_ACCOUNT_SLUG_KEY)

        private fun isStartOnLoginManaged(): Boolean = sharedPreferences.contains(MANAGED_START_ON_LOGIN_KEY)

        private fun isConnectOnStartManaged(): Boolean = sharedPreferences.contains(MANAGED_CONNECT_ON_START_KEY)

        fun hasRequestedNotificationPermission(): Boolean = sharedPreferences.getBoolean(NOTIFICATION_PERMISSION_REQUESTED_KEY, false)

        fun setNotificationPermissionRequested() {
            sharedPreferences.edit().putBoolean(NOTIFICATION_PERMISSION_REQUESTED_KEY, true).apply()
        }

        private fun saveUserConfigSync(value: Config) =
            sharedPreferences
                .edit()
                .putString(AUTH_URL_KEY, value.authUrl)
                .putString(API_URL_KEY, value.apiUrl)
                .putString(LOG_FILTER_KEY, value.logFilter)
                .putString(ACCOUNT_SLUG_KEY, value.accountSlug)
                .putBoolean(START_ON_LOGIN_KEY, value.startOnLogin)
                .putBoolean(CONNECT_ON_START_KEY, value.connectOnStart)
                .apply()

        private fun Config.withManagedOverrides(): Config =
            copy(
                authUrl = sharedPreferences.getString(MANAGED_AUTH_URL_KEY, null) ?: authUrl,
                apiUrl = sharedPreferences.getString(MANAGED_API_URL_KEY, null) ?: apiUrl,
                logFilter = sharedPreferences.getString(MANAGED_LOG_FILTER_KEY, null) ?: logFilter,
                accountSlug = sharedPreferences.getString(MANAGED_ACCOUNT_SLUG_KEY, null) ?: accountSlug,
                startOnLogin =
                    if (sharedPreferences.contains(MANAGED_START_ON_LOGIN_KEY)) {
                        sharedPreferences.getBoolean(MANAGED_START_ON_LOGIN_KEY, false)
                    } else {
                        startOnLogin
                    },
                connectOnStart =
                    if (sharedPreferences.contains(MANAGED_CONNECT_ON_START_KEY)) {
                        sharedPreferences.getBoolean(MANAGED_CONNECT_ON_START_KEY, false)
                    } else {
                        connectOnStart
                    },
            )

        private fun hashAuthState(state: String): String =
            MessageDigest
                .getInstance("SHA-256")
                .digest(state.toByteArray(Charsets.UTF_8))
                .joinToString(separator = "") { byte -> "%02x".format(byte.toInt() and 0xff) }

        private fun constantTimeEquals(
            expected: String?,
            actual: String,
        ): Boolean =
            expected?.let {
                MessageDigest.isEqual(
                    it.toByteArray(Charsets.UTF_8),
                    actual.toByteArray(Charsets.UTF_8),
                )
            } ?: false

        companion object {
            private const val AUTH_URL_KEY = "authUrl"
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
            private const val PENDING_AUTH_HANDOFF_STATE_HASH_KEY = "pendingAuthHandoffStateHash"
            private const val DEVICE_ID_KEY = "deviceId"
            private const val ENABLED_INTERNET_RESOURCE_KEY = "enabledInternetResource"
            private const val NOTIFICATION_PERMISSION_REQUESTED_KEY = "notificationPermissionRequested"
        }
    }
