// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.auth

import android.app.Application
import android.content.Context
import android.net.Uri
import android.os.Bundle
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.data.TokenStore
import dev.firezone.android.core.data.model.ControlPlane
import dev.firezone.android.core.data.model.SignInSettings
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class)
class AuthCallbackHandlerTest {
    private val session = PendingAuthSession()
    private lateinit var repo: Repository
    private lateinit var tokenStore: TokenStore
    private lateinit var handler: AuthCallbackHandler
    private val originalSettings = SignInSettings("example-corp", "https://custom.example.com", "wss://custom-api.example.com")

    @Before
    fun setUp() {
        val context = RuntimeEnvironment.getApplication()
        val preferences = context.getSharedPreferences("auth-callback-handler-test", Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
        repo = Repository(context, Dispatchers.Unconfined, preferences)
        tokenStore = TokenStore(preferences)
        handler = AuthCallbackHandler(session, tokenStore, repo)
        repo.saveSettingsSync(
            repo.getDefaultConfigSync().copy(
                accountSlug = originalSettings.accountSlug,
                authUrl = originalSettings.authUrl,
                apiUrl = originalSettings.apiUrl,
                logFilter = "debug",
                startOnLogin = true,
                connectOnStart = true,
            ),
        )
        repo.saveLastCustomUrlsSync(originalSettings.authUrl, originalSettings.apiUrl)
    }

    @Test
    fun `validated regions update saved and active URLs without changing other settings`() {
        val initial = repo.getConfigSync()

        for ((region, controlPlane) in listOf("us" to ControlPlane.CLOUD_US, "eu" to ControlPlane.CLOUD_EU)) {
            session.begin("nonce-", STATE, originalSettings)

            val outcome = handler.handle(callback(region))

            val expected = initial.copy(authUrl = checkNotNull(controlPlane.authUrl), apiUrl = checkNotNull(controlPlane.apiUrl))
            assertEquals(expected, repo.getConfigSync())
            assertEquals(
                originalSettings.copy(authUrl = expected.authUrl, apiUrl = expected.apiUrl),
                repo.getActiveSignInSettingsSync(),
            )
            assertEquals(AuthCallbackOutcome.Success("nonce-fragment", checkNotNull(repo.getActiveSignInSettingsSync())), outcome)
            assertEquals(originalSettings.authUrl to originalSettings.apiUrl, repo.getLastCustomUrlsSync())
        }
    }

    @Test
    fun `missing and unknown regions preserve current settings and the captured sign-in settings`() {
        val desired = repo.getConfigSync().copy(authUrl = "https://next.example.com", apiUrl = "wss://next-api.example.com")
        repo.saveSettingsSync(desired)

        for (region in listOf(null, "unknown")) {
            session.begin("nonce-", STATE, originalSettings)

            val outcome = handler.handle(callback(region))

            assertEquals(AuthCallbackOutcome.Success("nonce-fragment", originalSettings), outcome)
            assertEquals(desired, repo.getConfigSync())
            assertEquals(originalSettings, repo.getActiveSignInSettingsSync())
        }
    }

    @Test
    fun `an invalid state cannot change the region or replace the active session`() {
        val initial = repo.getConfigSync()
        repo.saveActiveSignInSettingsSync(originalSettings)
        tokenStore.save("existing-token")
        session.begin("nonce-", STATE, originalSettings)

        val outcome = handler.handle(callback("eu", state = "wrong-state"))

        assertTrue(outcome is AuthCallbackOutcome.Error)
        assertEquals(initial, repo.getConfigSync())
        assertEquals(originalSettings, repo.getActiveSignInSettingsSync())
        assertEquals("existing-token", tokenStore.get())
        assertTrue(session.hasPendingRequest())
    }

    @Test
    fun `region changes honor managed URLs and capture the effective endpoints`() =
        runBlocking {
            for ((manageAuth, manageApi) in listOf(true to false, false to true, true to true)) {
                repo
                    .saveManagedConfiguration(
                        Bundle().apply {
                            if (manageAuth) putString("authUrl", "https://managed.example.com")
                            if (manageApi) putString("apiUrl", "wss://managed-api.example.com")
                        },
                    ).first()
                val initial = repo.getConfigSync()
                session.begin("nonce-", STATE, originalSettings)

                handler.handle(callback("eu"))

                val expected =
                    initial.copy(
                        authUrl = if (manageAuth) initial.authUrl else checkNotNull(ControlPlane.CLOUD_EU.authUrl),
                        apiUrl = if (manageApi) initial.apiUrl else checkNotNull(ControlPlane.CLOUD_EU.apiUrl),
                    )
                assertEquals(expected, repo.getConfigSync())
                assertEquals(
                    originalSettings.copy(authUrl = expected.authUrl, apiUrl = expected.apiUrl),
                    repo.getActiveSignInSettingsSync(),
                )
            }
        }

    private fun callback(
        region: String?,
        state: String = STATE,
    ): Uri =
        Uri
            .Builder()
            .scheme(AUTH_CALLBACK_SCHEME)
            .authority(AUTH_CALLBACK_HOST)
            .appendQueryParameter("state", state)
            .appendQueryParameter("fragment", "fragment")
            .apply { region?.let { appendQueryParameter("region", it) } }
            .build()

    private companion object {
        const val STATE = "expected-state"
    }
}
