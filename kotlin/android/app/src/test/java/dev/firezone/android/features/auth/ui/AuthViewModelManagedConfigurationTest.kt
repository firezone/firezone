// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.auth.ui

import android.app.Application
import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.os.Looper
import dev.firezone.android.core.data.ManagedConfigurationReader
import dev.firezone.android.core.data.ManagedConfigurationSource
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.data.TokenStore
import dev.firezone.android.features.auth.AuthCallbackHandler
import dev.firezone.android.features.auth.PendingAuthSession
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class)
class AuthViewModelManagedConfigurationTest {
    private lateinit var repository: Repository
    private lateinit var viewModel: AuthViewModel

    @Before
    fun setUp() {
        val context: Application = RuntimeEnvironment.getApplication()
        val sharedPreferences =
            context.getSharedPreferences("auth-managed-configuration-test", Context.MODE_PRIVATE)
        sharedPreferences.edit().clear().commit()
        repository = Repository(context, Dispatchers.Unconfined, sharedPreferences)
        val restrictions =
            Bundle().apply {
                putString("authUrl", "https://managed.example.com")
                putString("accountSlug", "managed-account")
            }
        val source =
            ManagedConfigurationSource(
                context,
                ManagedConfigurationReader { Bundle(restrictions) },
                repository,
                CoroutineScope(SupervisorJob() + Dispatchers.Unconfined),
            )
        val pendingAuthSession = PendingAuthSession()
        viewModel =
            AuthViewModel(
                repository,
                pendingAuthSession,
                AuthCallbackHandler(pendingAuthSession, TokenStore(sharedPreferences)),
                source,
            )
    }

    @Test
    fun `authentication uses the latest managed URL and account`() {
        viewModel.startAuthFlow()
        shadowOf(Looper.getMainLooper()).idle()

        val action = viewModel.actionStateFlow.value as AuthViewModel.ViewAction.LaunchAuthFlow
        val uri = Uri.parse(action.url)
        assertEquals("https", uri.scheme)
        assertEquals("managed.example.com", uri.host)
        assertEquals("/managed-account", uri.path)
        assertFalse(uri.getQueryParameter("state").isNullOrBlank())
        assertFalse(uri.getQueryParameter("nonce").isNullOrBlank())
        assertEquals("gui-client", uri.getQueryParameter("as"))
    }
}
