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

/** Managed-configuration key naming the KeyChain alias to present to the portal. */
const val X509_CERTIFICATE_ALIAS_RESTRICTION: String = "x509CertificateAlias"

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
        private val authStateLock = Any()

        fun getConfigSync(): Config = getUserConfigSync().withManagedOverrides()

        fun getConfig(): Flow<Config> =
            flow {
                emit(getConfigSync())
            }.flowOn(coroutineDispatcher)

        fun getDefaultConfigSync(): Config = getBuildDefaultConfig().withManagedOverrides()

        fun getDefaultConfig(): Flow<Config> =
            flow {
                emit(getDefaultConfigSync())
            }.flowOn(coroutineDispatcher)

        fun saveSettings(value: Config): Flow<Unit> =
            flow {
                val managedStatus = getManagedStatus()
                val editor = sharedPreferences.edit()

                if (!managedStatus.isAuthUrlManaged) {
                    editor.putString(AUTH_URL_KEY, value.authUrl)
                }
                if (!managedStatus.isApiUrlManaged) {
                    editor.putString(API_URL_KEY, value.apiUrl)
                }
                if (!managedStatus.isLogFilterManaged) {
                    editor.putString(LOG_FILTER_KEY, value.logFilter)
                }
                if (!managedStatus.isAccountSlugManaged) {
                    editor.putString(ACCOUNT_SLUG_KEY, value.accountSlug)
                }
                if (!managedStatus.isStartOnLoginManaged) {
                    editor.putBoolean(START_ON_LOGIN_KEY, value.startOnLogin)
                }
                if (!managedStatus.isConnectOnStartManaged) {
                    editor.putBoolean(CONNECT_ON_START_KEY, value.connectOnStart)
                }

                emit(editor.apply())
            }.flowOn(coroutineDispatcher)

        // TODO: Consider adding support for the legacy managed configuration keys like token,
        //  allowedApplications, etc from pilot customer.
        fun saveManagedConfiguration(bundle: Bundle): Flow<Unit> =
            flow {
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

                emit(editor.apply())
            }.flowOn(coroutineDispatcher)

        /**
         * The KeyChain alias of the client certificate to present to the portal.
         *
         * A managed configuration overrides whatever the user picked, and one that sets the alias to
         * an empty value turns certificate-based device attestation off entirely.
         */
        fun getX509CertificateAliasSync(applicationRestrictions: Bundle): String? =
            if (isX509CertificateAliasManaged(applicationRestrictions)) {
                applicationRestrictions
                    .getString(X509_CERTIFICATE_ALIAS_RESTRICTION)
                    ?.takeUnless(String::isBlank)
            } else {
                sharedPreferences
                    .getString(X509_CERTIFICATE_ALIAS_KEY, null)
                    ?.takeUnless(String::isBlank)
            }

        fun isX509CertificateAliasManaged(applicationRestrictions: Bundle): Boolean =
            applicationRestrictions.containsKey(X509_CERTIFICATE_ALIAS_RESTRICTION)

        fun saveX509CertificateAliasSync(alias: String?) {
            sharedPreferences.edit().apply {
                if (alias == null) {
                    remove(X509_CERTIFICATE_ALIAS_KEY)
                } else {
                    putString(X509_CERTIFICATE_ALIAS_KEY, alias)
                }
                apply()
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
                    .remove(CONSUMED_AUTH_STATE_HASH_KEY)
                    .apply()
            }
        }

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

        fun saveAuthCallbackIfStateValid(
            state: String,
            fragment: String,
            accountSlug: String,
            actorName: String,
        ): Flow<Boolean> =
            flow {
                val isAccepted =
                    synchronized(authStateLock) {
                        val stateHash = hashAuthState(state)
                        val consumedStateHash = sharedPreferences.getString(CONSUMED_AUTH_STATE_HASH_KEY, null)
                        val isConsumedState =
                            consumedStateHash?.let {
                                MessageDigest.isEqual(
                                    it.toByteArray(Charsets.UTF_8),
                                    stateHash.toByteArray(Charsets.UTF_8),
                                )
                            } ?: false
                        val expectedState = sharedPreferences.getString(STATE_KEY, "").orEmpty()
                        when {
                            isConsumedState -> true
                            !MessageDigest.isEqual(expectedState.toByteArray(), state.toByteArray()) -> false
                            else -> {
                                val nonce = sharedPreferences.getString(NONCE_KEY, "").orEmpty()
                                sharedPreferences
                                    .edit()
                                    .putString(TOKEN_KEY, nonce.plus(fragment))
                                    .remove(NONCE_KEY)
                                    .remove(STATE_KEY)
                                    .putString(ACCOUNT_SLUG_KEY, accountSlug)
                                    .putString(ACTOR_NAME_KEY, actorName)
                                    .putString(CONSUMED_AUTH_STATE_HASH_KEY, stateHash)
                                    .apply()

                                true
                            }
                        }
                    }

                emit(isAccepted)
            }.flowOn(coroutineDispatcher)

        fun clearToken() {
            synchronized(authStateLock) {
                sharedPreferences.edit().apply {
                    remove(TOKEN_KEY)
                    remove(CONSUMED_AUTH_STATE_HASH_KEY)
                    apply()
                }
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

        fun hasRequestedNotificationPermission(): Boolean = sharedPreferences.getBoolean(NOTIFICATION_PERMISSION_REQUESTED_KEY, false)

        fun setNotificationPermissionRequested() {
            sharedPreferences.edit().putBoolean(NOTIFICATION_PERMISSION_REQUESTED_KEY, true).apply()
        }

        private fun getUserConfigSync(): Config {
            val defaults = getBuildDefaultConfig()

            return Config(
                authUrl = sharedPreferences.getString(AUTH_URL_KEY, null) ?: defaults.authUrl,
                apiUrl = sharedPreferences.getString(API_URL_KEY, null) ?: defaults.apiUrl,
                logFilter = sharedPreferences.getString(LOG_FILTER_KEY, null) ?: defaults.logFilter,
                accountSlug = sharedPreferences.getString(ACCOUNT_SLUG_KEY, null) ?: defaults.accountSlug,
                startOnLogin = sharedPreferences.getBoolean(START_ON_LOGIN_KEY, defaults.startOnLogin),
                connectOnStart = sharedPreferences.getBoolean(CONNECT_ON_START_KEY, defaults.connectOnStart),
            )
        }

        private fun getBuildDefaultConfig(): Config =
            Config(
                authUrl = BuildConfig.AUTH_URL,
                apiUrl = BuildConfig.API_URL,
                logFilter = BuildConfig.LOG_FILTER,
                accountSlug = "",
                startOnLogin = false,
                connectOnStart = false,
            )

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

        companion object {
            private const val AUTH_URL_KEY = "authUrl"
            private const val API_URL_KEY = "apiUrl"
            private const val FAVORITE_RESOURCES_KEY = "favoriteResources"
            private const val LOG_FILTER_KEY = "logFilter"
            private const val ACCOUNT_SLUG_KEY = "accountSlug"
            private const val START_ON_LOGIN_KEY = "startOnLogin"
            private const val CONNECT_ON_START_KEY = "connectOnStart"
            private const val X509_CERTIFICATE_ALIAS_KEY = "x509CertificateAlias"
            private const val MANAGED_AUTH_URL_KEY = "managedAuthUrl"
            private const val MANAGED_API_URL_KEY = "managedApiUrl"
            private const val MANAGED_LOG_FILTER_KEY = "managedLogFilter"
            private const val MANAGED_ACCOUNT_SLUG_KEY = "managedAccountSlug"
            private const val MANAGED_START_ON_LOGIN_KEY = "managedStartOnLogin"
            private const val MANAGED_CONNECT_ON_START_KEY = "managedConnectOnStart"
            private const val TOKEN_KEY = "token"
            private const val NONCE_KEY = "nonce"
            private const val STATE_KEY = "state"
            private const val CONSUMED_AUTH_STATE_HASH_KEY = "consumedAuthStateHash"
            private const val DEVICE_ID_KEY = "deviceId"
            private const val ENABLED_INTERNET_RESOURCE_KEY = "enabledInternetResource"
            private const val NOTIFICATION_PERMISSION_REQUESTED_KEY = "notificationPermissionRequested"
        }
    }
