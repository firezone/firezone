// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.auth.ui

import android.app.Application
import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import android.os.Looper
import dev.firezone.android.core.data.Repository
import dev.firezone.android.features.auth.AUTH_CALLBACK_SCHEME
import dev.firezone.android.features.auth.AuthCallbackHandler
import dev.firezone.android.features.auth.PendingAuthSession
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asCoroutineDispatcher
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
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class)
class AuthViewModelTest {
    private lateinit var context: Context
    private lateinit var preferences: SharedPreferences
    private lateinit var repository: Repository
    private lateinit var pendingAuthSession: PendingAuthSession
    private lateinit var viewModel: AuthViewModel

    @Before
    fun setUp() {
        context = RuntimeEnvironment.getApplication()
        preferences = context.getSharedPreferences("auth-view-model", Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
        repository = Repository(context, Dispatchers.Unconfined, preferences)
        pendingAuthSession = PendingAuthSession()
        viewModel = AuthViewModel(repository, pendingAuthSession, AuthCallbackHandler(pendingAuthSession, repository))
    }

    @Test
    fun `direct auth result persists token and consumes shared request`() =
        runBlocking {
            pendingAuthSession.begin(nonce = "nonce-", state = EXPECTED_STATE)
            val callback = callbackUri(state = EXPECTED_STATE, fragment = "fragment")

            assertEquals(AuthViewModel.ViewAction.AuthFlowComplete, viewModel.handleAuthCallback(callback))
            assertEquals("nonce-fragment", repository.getTokenSync())
            assertTrue(viewModel.handleAuthCallback(callback) is AuthViewModel.ViewAction.AuthFlowError)
            assertEquals("nonce-fragment", repository.getTokenSync())
        }

    @Test
    fun `null direct auth result is rejected without persisting token`() =
        runBlocking {
            pendingAuthSession.begin(nonce = "nonce-", state = EXPECTED_STATE)

            val action = viewModel.handleAuthCallback(null)

            assertTrue(action is AuthViewModel.ViewAction.AuthFlowError)
            assertNull(repository.getTokenSync())
        }

    @Test
    fun `mismatched direct auth result leaves token and pending request intact`() =
        runBlocking {
            repository.saveToken("existing-token").first()
            pendingAuthSession.begin(nonce = "nonce-", state = EXPECTED_STATE)

            val invalid = viewModel.handleAuthCallback(callbackUri(state = "other-state", fragment = "fragment"))

            assertTrue(invalid is AuthViewModel.ViewAction.AuthFlowError)
            assertEquals("existing-token", repository.getTokenSync())
            assertEquals(
                AuthViewModel.ViewAction.AuthFlowComplete,
                viewModel.handleAuthCallback(callbackUri(state = EXPECTED_STATE, fragment = "fragment")),
            )
            assertEquals("nonce-fragment", repository.getTokenSync())
        }

    @Test
    fun `fresh view model restores only an in-memory pending flow`() {
        assertFalse(viewModel.canRestoreAuthFlow())

        pendingAuthSession.begin(nonce = "nonce-", state = EXPECTED_STATE)

        assertTrue(viewModel.canRestoreAuthFlow())
    }

    @Test
    fun `callback remains restorable while token persistence is blocked after consumption`() {
        val executor = Executors.newSingleThreadExecutor()
        val dispatcher = executor.asCoroutineDispatcher()
        val blockingPreferences = BlockingAuthTokenPreferences(preferences)
        val raceRepository = Repository(context, dispatcher, blockingPreferences)
        val raceSession = PendingAuthSession()
        val raceViewModel =
            AuthViewModel(
                raceRepository,
                raceSession,
                AuthCallbackHandler(raceSession, raceRepository),
            )
        var tokenApplyStarted = false

        raceSession.begin(nonce = "nonce-", state = EXPECTED_STATE)

        try {
            raceViewModel.processAuthCallback(callbackUri(state = EXPECTED_STATE, fragment = "fragment"))
            shadowOf(Looper.getMainLooper()).idle()
            blockingPreferences.awaitTokenApply()
            tokenApplyStarted = true

            assertFalse(raceSession.hasPendingRequest())
            assertNull(raceViewModel.actionStateFlow.value)
            assertTrue(raceViewModel.canRestoreAuthFlow())
        } finally {
            blockingPreferences.releaseTokenApply()
            if (tokenApplyStarted) {
                blockingPreferences.awaitTokenApplied()
            }
            dispatcher.close()
            executor.awaitTermination(10, TimeUnit.SECONDS)
            executor.shutdownNow()
            shadowOf(Looper.getMainLooper()).idle()
        }
    }

    private fun callbackUri(
        state: String,
        fragment: String,
    ): Uri =
        Uri
            .Builder()
            .scheme(AUTH_CALLBACK_SCHEME)
            .authority("handle_client_sign_in_callback")
            .appendQueryParameter("state", state)
            .appendQueryParameter("fragment", fragment)
            .build()

    private companion object {
        const val EXPECTED_STATE = "expected-state"
    }
}

private class BlockingAuthTokenPreferences(
    private val delegate: SharedPreferences,
) : SharedPreferences by delegate {
    private val tokenApplyStarted = CountDownLatch(1)
    private val tokenApplyRelease = CountDownLatch(1)
    private val tokenApplied = CountDownLatch(1)

    override fun edit(): SharedPreferences.Editor {
        val editor = delegate.edit()
        var writesToken = false
        return object : SharedPreferences.Editor by editor {
            override fun putString(
                key: String?,
                value: String?,
            ): SharedPreferences.Editor {
                writesToken = writesToken || key == "token"
                editor.putString(key, value)
                return this
            }

            override fun apply() {
                if (writesToken) {
                    tokenApplyStarted.countDown()
                    check(tokenApplyRelease.await(10, TimeUnit.SECONDS))
                }
                editor.apply()
                if (writesToken) {
                    tokenApplied.countDown()
                }
            }
        }
    }

    fun awaitTokenApply() {
        check(tokenApplyStarted.await(10, TimeUnit.SECONDS))
    }

    fun releaseTokenApply() {
        tokenApplyRelease.countDown()
    }

    fun awaitTokenApplied() {
        check(tokenApplied.await(10, TimeUnit.SECONDS))
    }
}
