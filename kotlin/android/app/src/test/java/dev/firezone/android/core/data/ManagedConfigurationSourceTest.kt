// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core.data

import android.app.Application
import android.content.Context
import android.content.RestrictionsManager
import android.content.SharedPreferences
import android.os.Bundle
import dev.firezone.android.core.data.model.Config
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config as RobolectricConfig

@RunWith(RobolectricTestRunner::class)
@RobolectricConfig(application = Application::class)
class ManagedConfigurationSourceTest {
    private lateinit var sharedPreferences: SharedPreferences
    private lateinit var repository: Repository
    private lateinit var source: ManagedConfigurationSource

    @Before
    fun setUp() {
        val context = RuntimeEnvironment.getApplication<Application>()
        sharedPreferences = context.getSharedPreferences("managed-configuration-source-test", Context.MODE_PRIVATE)
        sharedPreferences.edit().clear().commit()
        repository = Repository(context, Dispatchers.Unconfined, sharedPreferences)
        source =
            ManagedConfigurationSource(
                context,
                context.getSystemService(RestrictionsManager::class.java)!!,
                repository,
                CoroutineScope(SupervisorJob() + Dispatchers.Unconfined),
            )
    }

    @Test
    fun `updates and revokes token and managed settings`() =
        runBlocking {
            repository.saveSettings(userConfig).first()

            source.applyRestrictions(
                Bundle().apply {
                    putString("token", "first-token")
                    putString("authUrl", "https://managed.example.com")
                    putBoolean("connectOnStart", true)
                },
            )

            assertEquals("first-token", source.configuration.value?.token)
            assertEquals("https://managed.example.com", repository.getConfigSync().authUrl)
            assertTrue(repository.getManagedStatus().isAuthUrlManaged)
            assertTrue(repository.getManagedStatus().isConnectOnStartManaged)

            source.applyRestrictions(
                Bundle().apply {
                    putString("token", "second-token")
                    putString("apiUrl", "wss://managed.example.com")
                },
            )

            assertEquals("second-token", source.configuration.value?.token)
            assertEquals(userConfig.authUrl, repository.getConfigSync().authUrl)
            assertEquals("wss://managed.example.com", repository.getConfigSync().apiUrl)
            assertFalse(repository.getManagedStatus().isAuthUrlManaged)
            assertFalse(repository.getManagedStatus().isConnectOnStartManaged)
            assertTrue(repository.getManagedStatus().isApiUrlManaged)

            source.applyRestrictions(Bundle())

            assertNull(source.configuration.value?.token)
            assertEquals(userConfig, repository.getConfigSync())
            assertFalse(repository.getManagedStatus().isApiUrlManaged)
        }

    private companion object {
        val userConfig =
            Config(
                authUrl = "https://user.example.com",
                apiUrl = "wss://user.example.com",
                logFilter = "info",
                accountSlug = "user-account",
                startOnLogin = false,
                connectOnStart = false,
            )
    }
}
