// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.auth

import android.app.Application
import android.content.Context
import android.net.Uri
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.data.TokenStore
import dev.firezone.android.core.data.model.SignInSettings
import dev.firezone.android.core.data.model.signInSettings
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class)
class PendingAuthSessionTest {
    private val session = PendingAuthSession()

    @Test
    fun `valid callback consumes pending request once`() {
        session.begin(nonce = "nonce-", state = EXPECTED_STATE, signedInWith = SIGN_IN_SETTINGS)
        val callback = callbackUri(state = EXPECTED_STATE, fragment = "fragment")

        assertEquals(
            AuthCallbackOutcome.Success("nonce-fragment", SIGN_IN_SETTINGS),
            session.complete(callback),
        )
        assertError(session.complete(callback), "No pending authentication request")
    }

    @Test
    fun `callback remembers the configuration used before settings changed`() =
        runBlocking {
            val context = RuntimeEnvironment.getApplication()
            val preferences = context.getSharedPreferences("pending-auth-session-test", Context.MODE_PRIVATE)
            preferences.edit().clear().commit()
            val repository = Repository(context, Dispatchers.Unconfined, preferences)
            val tokenStore = TokenStore(preferences)
            val originalConfig = repository.getConfigSync().signInSettings()
            session.begin(nonce = "nonce-", state = EXPECTED_STATE, signedInWith = originalConfig)

            repository.saveSettings(repository.getConfigSync().copy(authUrl = "https://eu.app.firezone.dev")).first()
            AuthCallbackHandler(session, tokenStore, repository).handle(callbackUri(state = EXPECTED_STATE, fragment = "fragment"))

            assertEquals("nonce-fragment", tokenStore.get())
            assertEquals(originalConfig, repository.getActiveSignInSettingsSync())
        }

    @Test
    fun `callback without pending request is rejected`() {
        assertError(
            session.complete(callbackUri(state = EXPECTED_STATE, fragment = "fragment")),
            "No pending authentication request",
        )
    }

    @Test
    fun `mismatched state is rejected without consuming pending request`() {
        session.begin(nonce = "nonce-", state = EXPECTED_STATE, signedInWith = SIGN_IN_SETTINGS)

        assertError(
            session.complete(callbackUri(state = "other-state", fragment = "fragment")),
            "Invalid state parameter",
        )
        assertEquals(
            AuthCallbackOutcome.Success("nonce-fragment", SIGN_IN_SETTINGS),
            session.complete(callbackUri(state = EXPECTED_STATE, fragment = "fragment")),
        )
    }

    @Test
    fun `malformed callbacks are rejected without consuming pending request`() {
        session.begin(nonce = "nonce-", state = EXPECTED_STATE, signedInWith = SIGN_IN_SETTINGS)
        val malformedCallbacks =
            listOf(
                null,
                Uri.parse("other-scheme://handle_client_sign_in_callback?state=$EXPECTED_STATE&fragment=fragment"),
                Uri.parse("$AUTH_CALLBACK_SCHEME://other-host?state=$EXPECTED_STATE&fragment=fragment"),
                callbackUri(state = null, fragment = "fragment"),
                callbackUri(state = " ", fragment = "fragment"),
                callbackUri(state = EXPECTED_STATE, fragment = null),
                callbackUri(state = EXPECTED_STATE, fragment = " "),
            )

        malformedCallbacks.forEach { callback ->
            assertTrue(session.complete(callback) is AuthCallbackOutcome.Error)
        }
        assertEquals(
            AuthCallbackOutcome.Success("nonce-fragment", SIGN_IN_SETTINGS),
            session.complete(callbackUri(state = EXPECTED_STATE, fragment = "fragment")),
        )
    }

    @Test
    fun `new request replaces previous request`() {
        session.begin(nonce = "old-nonce-", state = "old-state", signedInWith = SIGN_IN_SETTINGS)
        session.begin(nonce = "new-nonce-", state = "new-state", signedInWith = SIGN_IN_SETTINGS)

        assertError(
            session.complete(callbackUri(state = "old-state", fragment = "fragment")),
            "Invalid state parameter",
        )
        assertEquals(
            AuthCallbackOutcome.Success("new-nonce-fragment", SIGN_IN_SETTINGS),
            session.complete(callbackUri(state = "new-state", fragment = "fragment")),
        )
    }

    @Test
    fun `canceling old request does not cancel replacement`() {
        session.begin(nonce = "old-nonce-", state = "old-state", signedInWith = SIGN_IN_SETTINGS)
        session.begin(nonce = "new-nonce-", state = "new-state", signedInWith = SIGN_IN_SETTINGS)

        session.cancel("old-state")

        assertEquals(
            AuthCallbackOutcome.Success("new-nonce-fragment", SIGN_IN_SETTINGS),
            session.complete(callbackUri(state = "new-state", fragment = "fragment")),
        )
    }

    @Test
    fun `concurrent callbacks consume pending request exactly once`() {
        session.begin(nonce = "nonce-", state = EXPECTED_STATE, signedInWith = SIGN_IN_SETTINGS)
        val executor = Executors.newFixedThreadPool(2)
        val ready = CountDownLatch(2)
        val start = CountDownLatch(1)

        try {
            val outcomes =
                listOf("first", "second")
                    .map { fragment ->
                        executor.submit<AuthCallbackOutcome> {
                            ready.countDown()
                            check(start.await(10, TimeUnit.SECONDS))
                            session.complete(callbackUri(state = EXPECTED_STATE, fragment = fragment))
                        }
                    }.also {
                        check(ready.await(10, TimeUnit.SECONDS))
                        start.countDown()
                    }.map { future -> future.get(10, TimeUnit.SECONDS) }

            assertEquals(1, outcomes.count { it is AuthCallbackOutcome.Success })
            assertEquals(1, outcomes.count { it is AuthCallbackOutcome.Error })
            assertTrue(
                outcomes
                    .filterIsInstance<AuthCallbackOutcome.Success>()
                    .single()
                    .token in setOf("nonce-first", "nonce-second"),
            )
        } finally {
            start.countDown()
            executor.shutdownNow()
        }
    }

    private fun assertError(
        outcome: AuthCallbackOutcome,
        expected: String,
    ) {
        check(outcome is AuthCallbackOutcome.Error)
        assertEquals(listOf(expected), outcome.errors)
    }

    private fun callbackUri(
        state: String?,
        fragment: String?,
    ): Uri =
        Uri
            .Builder()
            .scheme(AUTH_CALLBACK_SCHEME)
            .authority("handle_client_sign_in_callback")
            .apply {
                state?.let { appendQueryParameter("state", it) }
                fragment?.let { appendQueryParameter("fragment", it) }
            }.build()

    private companion object {
        const val EXPECTED_STATE = "expected-state"
        val SIGN_IN_SETTINGS = SignInSettings("example-corp", "https://app.firezone.dev", "wss://api.firezone.dev")
    }
}
