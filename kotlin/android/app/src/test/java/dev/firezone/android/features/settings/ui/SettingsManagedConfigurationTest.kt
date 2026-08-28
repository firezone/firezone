// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui

import android.app.Application
import android.content.Context
import android.content.RestrictionsManager
import android.os.Bundle
import android.os.Looper
import dev.firezone.android.core.data.ManagedConfigurationSource
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.data.model.Config
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config as RobolectricConfig

@RunWith(RobolectricTestRunner::class)
@RobolectricConfig(application = Application::class)
class SettingsManagedConfigurationTest {
    private lateinit var repository: Repository
    private lateinit var source: ManagedConfigurationSource
    private lateinit var viewModel: SettingsViewModel

    @Before
    fun setUp() {
        val context = RuntimeEnvironment.getApplication<Application>()
        val sharedPreferences = context.getSharedPreferences("settings-managed-configuration-test", Context.MODE_PRIVATE)
        sharedPreferences.edit().clear().commit()
        repository = Repository(context, Dispatchers.Unconfined, sharedPreferences)
        source =
            ManagedConfigurationSource(
                context,
                context.getSystemService(RestrictionsManager::class.java)!!,
                repository,
                CoroutineScope(SupervisorJob() + Dispatchers.Unconfined),
            )
        viewModel = SettingsViewModel(repository, source)
    }

    @Test
    fun `open settings follow managed configuration changes`() =
        runBlocking {
            repository.saveSettings(userConfig).first()

            source.applyRestrictions(
                Bundle().apply {
                    putString("authUrl", "https://managed.example.com")
                    putBoolean("connectOnStart", true)
                },
            )
            shadowOf(Looper.getMainLooper()).idle()

            assertEquals("https://managed.example.com", viewModel.configStateFlow.value.authUrl)
            assertTrue(viewModel.configStateFlow.value.connectOnStart)
            assertTrue(viewModel.managedStatusStateFlow.value!!.isAuthUrlManaged)
            assertTrue(viewModel.managedStatusStateFlow.value!!.isConnectOnStartManaged)

            viewModel.onValidateLogFilter("trace")
            source.applyRestrictions(Bundle())
            shadowOf(Looper.getMainLooper()).idle()

            assertEquals(userConfig.copy(logFilter = "trace"), viewModel.configStateFlow.value)
            assertFalse(viewModel.managedStatusStateFlow.value!!.isAuthUrlManaged)
            assertFalse(viewModel.managedStatusStateFlow.value!!.isConnectOnStartManaged)
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
