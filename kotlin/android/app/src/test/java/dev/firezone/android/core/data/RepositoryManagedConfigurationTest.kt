// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core.data

import android.app.Application
import android.content.Context
import android.content.SharedPreferences
import android.os.Bundle
import dev.firezone.android.core.data.model.ManagedConfigStatus
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import dev.firezone.android.core.data.model.Config as FirezoneConfig

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class)
class RepositoryManagedConfigurationTest {
    private lateinit var sharedPreferences: SharedPreferences
    private lateinit var repository: Repository

    @Before
    fun setUp() {
        sharedPreferences =
            RuntimeEnvironment
                .getApplication()
                .getSharedPreferences("managed-configuration-test", Context.MODE_PRIVATE)
        sharedPreferences.edit().clear().commit()
        repository = Repository(Dispatchers.Unconfined, sharedPreferences)
    }

    @Test
    fun `latest managed configuration replaces previous overlay`() =
        runBlocking {
            repository.saveUserConfig(userConfig)
            repository.saveManagedConfiguration(allManagedConfig())

            repository
                .saveManagedConfiguration(
                    Bundle().apply {
                        putString(API_URL_KEY, "wss://replacement.example.com")
                        putBoolean(CONNECT_ON_START_KEY, false)
                    },
                )

            assertEquals(
                userConfig.copy(
                    apiUrl = "wss://replacement.example.com",
                    connectOnStart = false,
                ),
                repository.getConfigSync(),
            )
            assertEquals(
                ManagedConfigStatus(
                    isAuthUrlManaged = false,
                    isApiUrlManaged = true,
                    isLogFilterManaged = false,
                    isAccountSlugManaged = false,
                    isStartOnLoginManaged = false,
                    isConnectOnStartManaged = true,
                ),
                repository.getManagedStatus(),
            )
        }

    @Test
    fun `revoking managed configuration restores user values`() =
        runBlocking {
            repository.saveUserConfig(userConfig)
            repository.saveManagedConfiguration(allManagedConfig())

            repository.saveManagedConfiguration(Bundle())

            assertEquals(userConfig, repository.getConfigSync())
            assertEquals(unmanagedStatus, repository.getManagedStatus())
        }

    @Test
    fun `saving user settings does not replace active managed values`() =
        runBlocking {
            repository.saveUserConfig(userConfig)
            repository
                .saveManagedConfiguration(
                    Bundle().apply {
                        putString(AUTH_URL_KEY, "https://managed.example.com")
                        putBoolean(CONNECT_ON_START_KEY, false)
                    },
                )

            val editedUserConfig =
                userConfig.copy(
                    authUrl = "https://unsaved.example.com",
                    logFilter = "trace",
                    accountSlug = "changed-account",
                )
            repository.saveUserConfig(editedUserConfig)

            assertEquals(
                editedUserConfig.copy(
                    authUrl = "https://managed.example.com",
                    connectOnStart = false,
                ),
                repository.getConfigSync(),
            )
            repository.saveManagedConfiguration(Bundle())

            assertEquals(editedUserConfig, repository.getConfigSync())
        }

    @Test
    fun `default configuration keeps managed values`() =
        runBlocking {
            repository
                .saveManagedConfiguration(
                    Bundle().apply {
                        putString(AUTH_URL_KEY, "https://managed.example.com")
                        putBoolean(CONNECT_ON_START_KEY, true)
                    },
                )

            val defaults =
                repository.getEffectiveConfigFromPersistedManaged(
                    repository.getDefaultUserConfigSync(),
                )

            assertEquals("https://managed.example.com", defaults.authUrl)
            assertTrue(defaults.connectOnStart)
        }

    @Test
    fun `revoking managed settings preserves the user certificate alias`() =
        runBlocking {
            repository.saveX509CertificateAliasSync("user-alias")
            val managedRestrictions =
                Bundle().apply {
                    putString(AUTH_URL_KEY, "https://managed.example.com")
                    putString(X509_CERTIFICATE_ALIAS_RESTRICTION, "managed-alias")
                }
            repository.saveManagedConfiguration(managedRestrictions)

            assertEquals("managed-alias", repository.getX509CertificateAliasSync(managedRestrictions))

            val revokedRestrictions = Bundle()
            repository.saveManagedConfiguration(revokedRestrictions)

            assertEquals("user-alias", repository.getX509CertificateAliasSync(revokedRestrictions))
        }

    private fun allManagedConfig(): Bundle =
        Bundle().apply {
            putString(AUTH_URL_KEY, "https://managed.example.com")
            putString(API_URL_KEY, "wss://managed.example.com")
            putString(LOG_FILTER_KEY, "debug")
            putString(ACCOUNT_SLUG_KEY, "managed-account")
            putBoolean(START_ON_LOGIN_KEY, true)
            putBoolean(CONNECT_ON_START_KEY, false)
        }

    private companion object {
        const val AUTH_URL_KEY = "authUrl"
        const val API_URL_KEY = "apiUrl"
        const val LOG_FILTER_KEY = "logFilter"
        const val ACCOUNT_SLUG_KEY = "accountSlug"
        const val START_ON_LOGIN_KEY = "startOnLogin"
        const val CONNECT_ON_START_KEY = "connectOnStart"

        val userConfig =
            FirezoneConfig(
                authUrl = "https://user.example.com",
                apiUrl = "wss://user.example.com",
                logFilter = "info",
                accountSlug = "user-account",
                startOnLogin = false,
                connectOnStart = true,
            )

        val unmanagedStatus =
            ManagedConfigStatus(
                isAuthUrlManaged = false,
                isApiUrlManaged = false,
                isLogFilterManaged = false,
                isAccountSlugManaged = false,
                isStartOnLoginManaged = false,
                isConnectOnStartManaged = false,
            )
    }
}
