// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.customuri.ui

import android.app.Application
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import dev.firezone.android.core.data.Repository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
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
class CustomUriViewModelTest {
    private lateinit var preferences: SharedPreferences
    private lateinit var repository: Repository
    private lateinit var viewModel: CustomUriViewModel

    @Before
    fun setUp() {
        val context = RuntimeEnvironment.getApplication()
        preferences = context.getSharedPreferences("custom-uri-view-model", Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
        repository = Repository(context, Dispatchers.Unconfined, preferences)
        viewModel = CustomUriViewModel(repository)
    }

    @Test
    fun `valid callback persists credentials and consumes state`() =
        runBlocking {
            repository.saveState(EXPECTED_STATE).collect()
            repository.saveNonce("nonce-").collect()

            val action = viewModel.handleCustomUri(callbackIntent(state = EXPECTED_STATE, fragment = "fragment"))

            assertEquals(CustomUriViewModel.ViewAction.AuthFlowComplete, action)
            assertEquals("new-account", repository.getAccountSlug().first())
            assertEquals("New Actor", repository.getActorName().first())
            assertEquals("nonce-fragment", repository.getTokenSync())
            assertNull(repository.getNonceSync())
            assertNull(repository.getStateSync())
        }

    @Test
    fun `missing state does not mutate credentials`() =
        assertInvalidCallbackDoesNotMutateCredentials(callbackIntent(state = null, fragment = "new-fragment"))

    @Test
    fun `invalid state does not mutate credentials`() =
        assertInvalidCallbackDoesNotMutateCredentials(callbackIntent(state = "invalid-state", fragment = "new-fragment"))

    @Test
    fun `missing and blank fragments do not mutate credentials`() {
        assertInvalidCallbackDoesNotMutateCredentials(callbackIntent(state = EXPECTED_STATE, fragment = null))
        assertInvalidCallbackDoesNotMutateCredentials(callbackIntent(state = EXPECTED_STATE, fragment = " "))
    }

    @Test
    fun `missing profile fields do not mutate credentials`() {
        assertInvalidCallbackDoesNotMutateCredentials(
            callbackIntent(state = EXPECTED_STATE, fragment = "new-fragment", accountSlug = null),
        )
        assertInvalidCallbackDoesNotMutateCredentials(
            callbackIntent(state = EXPECTED_STATE, fragment = "new-fragment", actorName = null),
        )
    }

    private fun assertInvalidCallbackDoesNotMutateCredentials(intent: Intent) =
        runBlocking {
            seedExistingCredentials()

            val action = viewModel.handleCustomUri(intent)

            check(action is CustomUriViewModel.ViewAction.AuthFlowError)
            assertEquals("existing-account", repository.getAccountSlug().first())
            assertEquals("Existing Actor", repository.getActorName().first())
            assertEquals("existing-nonce-existing-fragment", repository.getTokenSync())
            assertEquals("existing-nonce-", repository.getNonceSync())
            assertEquals(EXPECTED_STATE, repository.getStateSync())
        }

    private suspend fun seedExistingCredentials() {
        preferences.edit().clear().commit()
        repository.saveAccountSlug("existing-account").collect()
        repository.saveActorName("Existing Actor").collect()
        repository.saveNonce("existing-nonce-").collect()
        repository.saveState(EXPECTED_STATE).collect()
        repository.saveToken("existing-fragment").collect()
    }

    private fun callbackIntent(
        state: String?,
        fragment: String?,
        accountSlug: String? = "new-account",
        actorName: String? = "New Actor",
    ): Intent {
        val uri =
            Uri
                .Builder()
                .scheme("firezone-fd0020211111")
                .authority("handle_client_sign_in_callback")
                .apply {
                    accountSlug?.let { appendQueryParameter("account_slug", it) }
                    actorName?.let { appendQueryParameter("actor_name", it) }
                    state?.let { appendQueryParameter("state", it) }
                    fragment?.let { appendQueryParameter("fragment", it) }
                }.build()

        return Intent(Intent.ACTION_VIEW, uri)
    }

    private companion object {
        const val EXPECTED_STATE = "expected-state"
    }
}
