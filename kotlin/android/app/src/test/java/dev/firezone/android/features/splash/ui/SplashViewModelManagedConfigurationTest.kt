// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.splash.ui

import android.app.Application
import android.content.Context
import android.os.Build
import android.os.Bundle
import android.os.Looper
import dev.firezone.android.core.ApplicationMode
import dev.firezone.android.core.data.ManagedConfigurationReader
import dev.firezone.android.core.data.ManagedConfigurationSource
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.x509.CertificateAccess
import dev.firezone.android.core.x509.SystemKeyChain
import dev.firezone.android.tunnel.TunnelService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [Build.VERSION_CODES.TIRAMISU])
class SplashViewModelManagedConfigurationTest {
    private lateinit var context: Application
    private lateinit var viewModel: SplashViewModel

    @Before
    fun setUp() {
        context = RuntimeEnvironment.getApplication()
        val sharedPreferences =
            context.getSharedPreferences("splash-managed-configuration-test", Context.MODE_PRIVATE)
        sharedPreferences.edit().clear().commit()
        val repository = Repository(context, Dispatchers.Unconfined, sharedPreferences)
        repository.setNotificationPermissionRequested()
        val restrictions =
            Bundle().apply {
                putString("token", "managed-token")
                putBoolean("connectOnStart", true)
            }
        val source =
            ManagedConfigurationSource(
                context,
                ManagedConfigurationReader { Bundle(restrictions) },
                repository,
                CoroutineScope(SupervisorJob() + Dispatchers.Unconfined),
            )
        val certificateAccess =
            CertificateAccess(
                repository = repository,
                managedConfigurationSource = source,
                keyChain = SystemKeyChain(context),
                coroutineDispatcher = Dispatchers.Unconfined,
            )
        viewModel = SplashViewModel(repository, source, ApplicationMode.TESTING, certificateAccess)
    }

    @Test
    fun `managed token and connect on start launch the tunnel`() {
        viewModel.checkTunnelState(context, isInitialLaunch = true)
        shadowOf(Looper.getMainLooper()).runToEndOfTasks()

        assertEquals(SplashViewModel.ViewAction.NavigateToSession, viewModel.actionStateFlow.value)
        val serviceIntent = shadowOf(context).nextStartedService
        assertEquals(TunnelService::class.java.name, serviceIntent.component?.className)
        assertTrue(serviceIntent.getBooleanExtra("startedByUser", false))
    }
}
