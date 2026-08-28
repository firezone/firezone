// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.customuri.ui

import android.app.Application
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import dev.firezone.android.core.data.Repository
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.flow.collect
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
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class)
class CustomUriViewModelTest {
    private lateinit var context: Context
    private lateinit var preferences: SharedPreferences
    private lateinit var repository: Repository
    private lateinit var viewModel: CustomUriViewModel

    @Before
    fun setUp() {
        context = RuntimeEnvironment.getApplication()
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
    fun `duplicate callback does not overwrite completed action`() =
        runBlocking {
            repository.saveState(EXPECTED_STATE).collect()
            repository.saveNonce("nonce-").collect()
            val intent = callbackIntent(state = EXPECTED_STATE, fragment = "fragment")

            viewModel.processCustomUri(intent)
            viewModel.processCustomUri(intent)

            assertEquals(CustomUriViewModel.ViewAction.AuthFlowComplete, viewModel.actionStateFlow.value)
            viewModel.clearAction()
            viewModel.processCustomUri(intent)
            assertNull(viewModel.actionStateFlow.value)
        }

    @Test
    fun `replayed callback completes after recreation without mutating credentials`() =
        runBlocking {
            repository.saveNonceAndStateSync(nonce = "nonce-", state = EXPECTED_STATE)
            val callback = callbackIntent(state = EXPECTED_STATE, fragment = "fragment")
            assertEquals(CustomUriViewModel.ViewAction.AuthFlowComplete, viewModel.handleCustomUri(callback))

            val recreatedRepository = Repository(context, Dispatchers.Unconfined, preferences)
            val recreatedViewModel = CustomUriViewModel(recreatedRepository)
            val replay =
                callbackIntent(
                    state = EXPECTED_STATE,
                    fragment = "replacement-fragment",
                    accountSlug = "replacement-account",
                    actorName = "Replacement Actor",
                )

            recreatedViewModel.processCustomUri(replay)

            assertEquals(CustomUriViewModel.ViewAction.AuthFlowComplete, recreatedViewModel.actionStateFlow.value)
            assertEquals("nonce-fragment", recreatedRepository.getTokenSync())
            assertEquals("new-account", recreatedRepository.getAccountSlug().first())
            assertEquals("New Actor", recreatedRepository.getActorNameSync())
            assertNull(recreatedRepository.getNonceSync())
            assertNull(recreatedRepository.getStateSync())
        }

    @Test
    fun `malformed replay fails after recreation without mutating credentials`() =
        runBlocking {
            repository.saveNonceAndStateSync(nonce = "nonce-", state = EXPECTED_STATE)
            val callback = callbackIntent(state = EXPECTED_STATE, fragment = "fragment")
            assertEquals(CustomUriViewModel.ViewAction.AuthFlowComplete, viewModel.handleCustomUri(callback))

            val recreatedRepository = Repository(context, Dispatchers.Unconfined, preferences)
            val recreatedViewModel = CustomUriViewModel(recreatedRepository)

            val action =
                recreatedViewModel.handleCustomUri(
                    callbackIntent(state = EXPECTED_STATE, fragment = " "),
                )

            assertTrue(action is CustomUriViewModel.ViewAction.AuthFlowError)
            assertEquals("nonce-fragment", recreatedRepository.getTokenSync())
            assertEquals("new-account", recreatedRepository.getAccountSlug().first())
            assertEquals("New Actor", recreatedRepository.getActorNameSync())
            assertNull(recreatedRepository.getNonceSync())
            assertNull(recreatedRepository.getStateSync())
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
    fun `missing and blank profile fields do not mutate credentials`() {
        assertInvalidCallbackDoesNotMutateCredentials(
            callbackIntent(state = EXPECTED_STATE, fragment = "new-fragment", accountSlug = null),
        )
        assertInvalidCallbackDoesNotMutateCredentials(
            callbackIntent(state = EXPECTED_STATE, fragment = "new-fragment", accountSlug = " "),
        )
        assertInvalidCallbackDoesNotMutateCredentials(
            callbackIntent(state = EXPECTED_STATE, fragment = "new-fragment", actorName = null),
        )
        assertInvalidCallbackDoesNotMutateCredentials(
            callbackIntent(state = EXPECTED_STATE, fragment = "new-fragment", actorName = " "),
        )
    }

    @Test
    fun `concurrent callbacks complete after consuming state once`() =
        runBlocking {
            val context = RuntimeEnvironment.getApplication()
            val delegate = context.getSharedPreferences("custom-uri-view-model-concurrent", Context.MODE_PRIVATE)
            delegate.edit().clear().commit()
            val coordinatedPreferences = CoordinatedStateReads(delegate)
            val executor = Executors.newFixedThreadPool(3)
            val dispatcher = executor.asCoroutineDispatcher()

            try {
                val repository = Repository(context, dispatcher, coordinatedPreferences)
                val viewModel = CustomUriViewModel(repository)
                repository.saveState(EXPECTED_STATE).collect()
                repository.saveNonce("nonce-").collect()
                coordinatedPreferences.resetAppliedTransactions()

                val first =
                    async(start = CoroutineStart.UNDISPATCHED) {
                        viewModel.handleCustomUri(callbackIntent(state = EXPECTED_STATE, fragment = "first"))
                    }
                val second =
                    async(start = CoroutineStart.UNDISPATCHED) {
                        viewModel.handleCustomUri(callbackIntent(state = EXPECTED_STATE, fragment = "second"))
                    }
                executor.execute {
                    coordinatedPreferences.awaitStateRead()
                    coordinatedPreferences.releaseStateReads()
                }

                val actions = awaitAll(first, second)

                assertEquals(2, actions.count { it == CustomUriViewModel.ViewAction.AuthFlowComplete })
                assertEquals(1, coordinatedPreferences.appliedTransactionCount())
                assertNull(repository.getNonceSync())
                assertNull(repository.getStateSync())
                assertTrue(repository.getTokenSync() in setOf("nonce-first", "nonce-second"))
            } finally {
                dispatcher.close()
            }
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

private class CoordinatedStateReads(
    private val delegate: SharedPreferences,
) : SharedPreferences by delegate {
    private val appliedTransactions = AtomicInteger()
    private val firstStateRead = CountDownLatch(1)
    private val stateReads = AtomicInteger()
    private val stateReadsRelease = CountDownLatch(1)

    override fun edit(): SharedPreferences.Editor {
        val editor = delegate.edit()
        return object : SharedPreferences.Editor by editor {
            override fun apply() {
                appliedTransactions.incrementAndGet()
                editor.apply()
            }
        }
    }

    override fun getString(
        key: String?,
        defValue: String?,
    ): String? {
        val value = delegate.getString(key, defValue)
        if (key != "state") {
            return value
        }

        firstStateRead.countDown()
        if (stateReads.incrementAndGet() == 2) {
            stateReadsRelease.countDown()
        }
        check(stateReadsRelease.await(10, TimeUnit.SECONDS))

        return value
    }

    fun awaitStateRead() {
        check(firstStateRead.await(10, TimeUnit.SECONDS))
    }

    fun releaseStateReads() {
        stateReadsRelease.countDown()
    }

    fun resetAppliedTransactions() {
        appliedTransactions.set(0)
    }

    fun appliedTransactionCount(): Int = appliedTransactions.get()
}
