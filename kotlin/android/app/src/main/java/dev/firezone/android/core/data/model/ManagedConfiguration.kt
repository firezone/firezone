// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core.data.model

import android.os.Bundle

internal enum class CredentialOrigin {
    MANAGED,
    USER,
}

internal fun CredentialOrigin.shouldClearSavedCredentials(requiresSignIn: Boolean): Boolean =
    requiresSignIn && this == CredentialOrigin.USER

internal data class SessionCredential(
    val token: String,
    val origin: CredentialOrigin,
)

internal data class ManagedConfiguration(
    val token: String? = null,
    val allowedApplications: String? = null,
    val disallowedApplications: String? = null,
    val deviceName: String? = null,
    val authUrl: String? = null,
    val apiUrl: String? = null,
    val logFilter: String? = null,
    val accountSlug: String? = null,
    val startOnLogin: Boolean? = null,
    val connectOnStart: Boolean? = null,
) {
    fun requiresSessionReconnect(previous: ManagedConfiguration): Boolean =
        token != previous.token ||
            deviceName != previous.deviceName ||
            apiUrl != previous.apiUrl ||
            accountSlug != previous.accountSlug

    fun requiresVpnRebuild(previous: ManagedConfiguration): Boolean =
        allowedApplications != previous.allowedApplications ||
            disallowedApplications != previous.disallowedApplications

    fun applyTo(userConfig: Config): Config =
        userConfig.copy(
            authUrl = authUrl ?: userConfig.authUrl,
            apiUrl = apiUrl ?: userConfig.apiUrl,
            logFilter = logFilter ?: userConfig.logFilter,
            accountSlug = accountSlug ?: userConfig.accountSlug,
            startOnLogin = startOnLogin ?: userConfig.startOnLogin,
            connectOnStart = connectOnStart ?: userConfig.connectOnStart,
        )

    fun managedStatus(): ManagedConfigStatus =
        ManagedConfigStatus(
            isAuthUrlManaged = authUrl != null,
            isApiUrlManaged = apiUrl != null,
            isLogFilterManaged = logFilter != null,
            isAccountSlugManaged = accountSlug != null,
            isStartOnLoginManaged = startOnLogin != null,
            isConnectOnStartManaged = connectOnStart != null,
        )

    fun resolveSessionCredential(userToken: String?): SessionCredential? {
        val origin = if (token != null) CredentialOrigin.MANAGED else CredentialOrigin.USER
        val resolvedToken = token ?: userToken

        // A present but blank managed token explicitly disables the saved user-token fallback.
        return resolvedToken?.takeIf { it.isNotBlank() }?.let { SessionCredential(it, origin) }
    }

    companion object {
        fun from(bundle: Bundle): ManagedConfiguration =
            ManagedConfiguration(
                token = bundle.getString(TOKEN_KEY),
                allowedApplications = bundle.getString(ALLOWED_APPLICATIONS_KEY),
                disallowedApplications = bundle.getString(DISALLOWED_APPLICATIONS_KEY),
                deviceName = bundle.getString(DEVICE_NAME_KEY),
                authUrl = bundle.getString(AUTH_URL_KEY),
                apiUrl = bundle.getString(API_URL_KEY),
                logFilter = bundle.getString(LOG_FILTER_KEY),
                accountSlug = bundle.getString(ACCOUNT_SLUG_KEY),
                startOnLogin = bundle.getBooleanOrNull(START_ON_LOGIN_KEY),
                connectOnStart = bundle.getBooleanOrNull(CONNECT_ON_START_KEY),
            )

        private fun Bundle.getBooleanOrNull(key: String): Boolean? =
            if (containsKey(key)) {
                getBoolean(key)
            } else {
                null
            }

        private const val TOKEN_KEY = "token"
        private const val ALLOWED_APPLICATIONS_KEY = "allowedApplications"
        private const val DISALLOWED_APPLICATIONS_KEY = "disallowedApplications"
        private const val DEVICE_NAME_KEY = "deviceName"
        private const val AUTH_URL_KEY = "authUrl"
        private const val API_URL_KEY = "apiUrl"
        private const val LOG_FILTER_KEY = "logFilter"
        private const val ACCOUNT_SLUG_KEY = "accountSlug"
        private const val START_ON_LOGIN_KEY = "startOnLogin"
        private const val CONNECT_ON_START_KEY = "connectOnStart"
    }
}
