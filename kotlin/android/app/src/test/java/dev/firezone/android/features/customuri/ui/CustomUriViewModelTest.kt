// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.customuri.ui

import android.app.Application
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import dev.firezone.android.core.data.Repository
import dev.firezone.android.features.auth.AUTH_CALLBACK_SCHEME
import dev.firezone.android.features.auth.AuthCallbackHandler
import dev.firezone.android.features.auth.PendingAuthSession
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class)
class CustomUriViewModelTest {
    private lateinit var preferences: SharedPreferences
    private lateinit var repository: Repository
    private lateinit var pendingAuthSession: PendingAuthSession
    private lateinit var viewModel: CustomUriViewModel

    @Before
    fun setUp() {
        val context: Context = RuntimeEnvironment.getApplication()
        preferences = context.getSharedPreferences("custom-uri-view-model", Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
        repository = Repository(context, Dispatchers.Unconfined, preferences)
        pendingAuthSession = PendingAuthSession()
        viewModel = newViewModel()
    }

    @Test
    fun `valid fallback callback persists credentials and consumes request`() =
        runBlocking {
            pendingAuthSession.begin(nonce = "nonce-", state = EXPECTED_STATE)
            val callback = callbackIntent(state = EXPECTED_STATE, fragment = "fragment")

            assertEquals(CustomUriViewModel.ViewAction.AuthFlowComplete, viewModel.handleCustomUri(callback))
            assertEquals("nonce-fragment", repository.getTokenSync())
            assertTrue(viewModel.handleCustomUri(callback) is CustomUriViewModel.ViewAction.AuthFlowError)
            assertEquals("nonce-fragment", repository.getTokenSync())
        }

    @Test
    fun `duplicate intent does not overwrite terminal action`() =
        runBlocking {
            pendingAuthSession.begin(nonce = "nonce-", state = EXPECTED_STATE)
            val callback = callbackIntent(state = EXPECTED_STATE, fragment = "fragment")

            viewModel.processCustomUri(callback)
            viewModel.processCustomUri(callback)

            assertEquals(CustomUriViewModel.ViewAction.AuthFlowComplete, viewModel.actionStateFlow.value)
            viewModel.clearAction()
            viewModel.processCustomUri(callback)
            assertNull(viewModel.actionStateFlow.value)
        }

    @Test
    fun `callback without pending request is rejected without replacing token`() =
        runBlocking {
            repository.saveToken("existing-token").first()

            val action =
                viewModel.handleCustomUri(
                    callbackIntent(state = EXPECTED_STATE, fragment = "replacement-fragment"),
                )

            assertTrue(action is CustomUriViewModel.ViewAction.AuthFlowError)
            assertEquals("existing-token", repository.getTokenSync())
        }

    @Test
    fun `invalid callback keeps token and pending request intact`() =
        runBlocking {
            repository.saveToken("existing-token").first()
            pendingAuthSession.begin(nonce = "nonce-", state = EXPECTED_STATE)

            val invalid = viewModel.handleCustomUri(callbackIntent(state = "other-state", fragment = "fragment"))

            assertTrue(invalid is CustomUriViewModel.ViewAction.AuthFlowError)
            assertEquals("existing-token", repository.getTokenSync())
            assertEquals(
                CustomUriViewModel.ViewAction.AuthFlowComplete,
                viewModel.handleCustomUri(callbackIntent(state = EXPECTED_STATE, fragment = "fragment")),
            )
            assertEquals("nonce-fragment", repository.getTokenSync())
        }

    @Test
    fun `separate handlers consume shared request exactly once`() =
        runBlocking {
            pendingAuthSession.begin(nonce = "nonce-", state = EXPECTED_STATE)
            val viewModels = listOf(newViewModel(), newViewModel())

            val actions =
                viewModels
                    .mapIndexed { index, candidate ->
                        async(Dispatchers.Default) {
                            candidate.handleCustomUri(
                                callbackIntent(state = EXPECTED_STATE, fragment = "fragment-$index"),
                            )
                        }
                    }.awaitAll()

            assertEquals(1, actions.count { it == CustomUriViewModel.ViewAction.AuthFlowComplete })
            assertEquals(1, actions.count { it is CustomUriViewModel.ViewAction.AuthFlowError })
            assertTrue(repository.getTokenSync() in setOf("nonce-fragment-0", "nonce-fragment-1"))
        }

    private fun newViewModel(): CustomUriViewModel =
        CustomUriViewModel(AuthCallbackHandler(pendingAuthSession, repository))

    private fun callbackIntent(
        state: String?,
        fragment: String?,
    ): Intent {
        val uri =
            Uri
                .Builder()
                .scheme(AUTH_CALLBACK_SCHEME)
                .authority("handle_client_sign_in_callback")
                .apply {
                    state?.let { appendQueryParameter("state", it) }
                    fragment?.let { appendQueryParameter("fragment", it) }
                }.build()

        return Intent(Intent.ACTION_VIEW, uri)
    }

    private companion object {
        const val EXPECTED_STATE = "expected-state"
    }
}
