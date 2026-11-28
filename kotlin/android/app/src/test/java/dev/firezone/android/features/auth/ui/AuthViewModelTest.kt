// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.auth.ui

import android.app.Application
import android.content.Context
import android.net.Uri
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.data.TokenStore
import dev.firezone.android.features.auth.AuthCallbackHandler
import dev.firezone.android.features.auth.PendingAuthSession
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class)
class AuthViewModelTest {
    private lateinit var repo: Repository
    private lateinit var tokenStore: TokenStore

    @Before
    fun setUp() {
        val context = RuntimeEnvironment.getApplication()
        val preferences = context.getSharedPreferences("auth-view-model-test", Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
        repo = Repository(context, Dispatchers.Unconfined, preferences)
        tokenStore = TokenStore(preferences)
    }

    @Test
    fun `hosted portals get an https callback when the browser supports Auth Tab`() {
        for (host in listOf("app.firezone.dev", "eu.app.firezone.dev")) {
            val launch = startAuthFlow(authUrl = "https://$host", authTabBrowser = BROWSER)

            assertEquals("https", launch.uri().getQueryParameter("callback"))
            assertEquals(AuthViewModel.HttpsCallback(host, BROWSER), launch.httpsCallback)
        }
    }

    @Test
    fun `the custom scheme callback is kept without Auth Tab or for other portals`() {
        val cases =
            listOf(
                "https://app.firezone.dev" to null,
                "https://custom.example.com" to BROWSER,
                "https://app.firezone.dev:8443" to BROWSER,
            )

        for ((authUrl, browser) in cases) {
            val launch = startAuthFlow(authUrl = authUrl, authTabBrowser = browser)

            assertNull(launch.uri().getQueryParameter("callback"))
            assertNull(launch.httpsCallback)
        }
    }

    private fun startAuthFlow(
        authUrl: String,
        authTabBrowser: String?,
    ): AuthViewModel.ViewAction.LaunchAuthFlow {
        repo.saveSettingsSync(repo.getConfigSync().copy(accountSlug = "example-corp", authUrl = authUrl))
        val session = PendingAuthSession()
        val viewModel = AuthViewModel(repo, session, AuthCallbackHandler(session, tokenStore, repo))

        viewModel.startAuthFlow(authTabBrowser)

        return viewModel.actionStateFlow.value as AuthViewModel.ViewAction.LaunchAuthFlow
    }

    private fun AuthViewModel.ViewAction.LaunchAuthFlow.uri(): Uri = Uri.parse(url)

    private companion object {
        const val BROWSER = "com.android.chrome"
    }
}
