// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core.data

import android.app.Application
import android.content.Context
import android.content.SharedPreferences
import kotlinx.coroutines.Dispatchers
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
import org.robolectric.annotation.Config
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class)
class RepositoryAuthStateTest {
    private lateinit var context: Context
    private lateinit var preferences: SharedPreferences

    @Before
    fun setUp() {
        context = RuntimeEnvironment.getApplication()
        preferences = context.getSharedPreferences("repository-auth-state", Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
    }

    @Test
    fun `nonce and state are persisted in one transaction`() {
        val recordingPreferences = RecordingSharedPreferences(preferences)
        val repository = newRepository(recordingPreferences)

        repository.saveNonceAndStateSync(nonce = "new-nonce", state = "new-state")

        assertEquals(
            listOf(
                PreferenceTransaction(
                    putStringKeys = setOf("nonce", "state"),
                    removedKeys = setOf("pendingAuthHandoffStateHash"),
                ),
            ),
            recordingPreferences.appliedTransactions,
        )
        assertEquals("new-nonce", repository.getNonceSync())
        assertEquals("new-state", repository.getStateSync())
    }

    @Test
    fun `callback persists credentials and pending handoff in one transaction`() =
        runBlocking {
            val recordingPreferences = RecordingSharedPreferences(preferences)
            val repository = newRepository(recordingPreferences)
            repository.saveNonceAndStateSync(nonce = "nonce-", state = "handoff-state")
            recordingPreferences.appliedTransactions.clear()

            assertEquals(
                AuthCallbackResult.NEW_HANDOFF,
                repository
                    .saveAuthCallbackIfStateValid(
                        state = "handoff-state",
                        fragment = "fragment",
                    ).first(),
            )

            assertEquals(
                listOf(
                    PreferenceTransaction(
                        putStringKeys = setOf("token", "pendingAuthHandoffStateHash"),
                        removedKeys = setOf("nonce", "state"),
                    ),
                ),
                recordingPreferences.appliedTransactions,
            )

            val recreatedRepository = newRepository(recordingPreferences)
            assertEquals(
                AuthCallbackResult.PENDING_HANDOFF,
                recreatedRepository
                    .saveAuthCallbackIfStateValid(
                        state = "handoff-state",
                        fragment = "replacement-fragment",
                    ).first(),
            )
            assertEquals(1, recordingPreferences.appliedTransactions.size)
            assertEquals("nonce-fragment", recreatedRepository.getTokenSync())
            assertNull(recreatedRepository.getNonceSync())
            assertNull(recreatedRepository.getStateSync())
        }

    @Test
    fun `new auth request invalidates pending handoff`() =
        runBlocking {
            val repository = newRepository(preferences)
            completeAuth(repository, state = "old-state")

            repository.saveNonceAndStateSync(nonce = "new-nonce-", state = "new-state")

            assertEquals(
                AuthCallbackResult.INVALID,
                repository
                    .saveAuthCallbackIfStateValid(
                        state = "old-state",
                        fragment = "replacement-fragment",
                    ).first(),
            )
            assertEquals("nonce-fragment", repository.getTokenSync())
            assertEquals("new-nonce-", repository.getNonceSync())
            assertEquals("new-state", repository.getStateSync())
        }

    @Test
    fun `partial and blank legacy requests reject callback without mutating durable state`() =
        runBlocking {
            listOf(
                null to "expected-state",
                "" to "expected-state",
                "existing-nonce-" to null,
                "existing-nonce-" to "",
            ).forEach { (nonce, state) ->
                val editor =
                    preferences
                        .edit()
                        .clear()
                        .putString("token", "existing-token")
                nonce?.let { editor.putString("nonce", it) }
                state?.let { editor.putString("state", it) }
                editor.commit()
                val repository = newRepository(preferences)

                assertEquals(
                    AuthCallbackResult.INVALID,
                    repository
                        .saveAuthCallbackIfStateValid(
                            state = "expected-state",
                            fragment = "replacement-fragment",
                        ).first(),
                )
                assertEquals("existing-token", repository.getTokenSync())
                assertEquals(nonce, repository.getNonceSync())
                assertEquals(state, repository.getStateSync())
            }
        }

    @Test
    fun `clearing credentials uses one transaction`() {
        preferences
            .edit()
            .putString("token", "existing-token")
            .putString("nonce", "existing-nonce")
            .putString("state", "existing-state")
            .putString("pendingAuthHandoffStateHash", "existing-hash")
            .putString("x509CertificateAlias", "existing-alias")
            .commit()
        val recordingPreferences = RecordingSharedPreferences(preferences)
        val repository = newRepository(recordingPreferences)

        repository.clearCredentials()

        assertEquals(
            listOf(
                PreferenceTransaction(
                    putStringKeys = emptySet(),
                    removedKeys = setOf("token", "nonce", "state", "pendingAuthHandoffStateHash"),
                ),
            ),
            recordingPreferences.appliedTransactions,
        )
        assertNull(repository.getTokenSync())
        assertNull(repository.getNonceSync())
        assertNull(repository.getStateSync())
        assertNull(preferences.getString("pendingAuthHandoffStateHash", null))
        assertEquals("existing-alias", preferences.getString("x509CertificateAlias", null))
    }

    @Test
    fun `clearing credentials invalidates pending handoff`() =
        runBlocking {
            val repository = newRepository(preferences)
            completeAuth(repository, state = "handoff-state")

            repository.clearCredentials()

            val recreatedRepository = newRepository(preferences)
            assertEquals(
                AuthCallbackResult.INVALID,
                recreatedRepository
                    .saveAuthCallbackIfStateValid(
                        state = "handoff-state",
                        fragment = "replacement-fragment",
                    ).first(),
            )
            assertNull(recreatedRepository.getTokenSync())
            assertNull(recreatedRepository.getNonceSync())
            assertNull(recreatedRepository.getStateSync())
        }

    @Test
    fun `clearing credentials waits for callback persistence and wins`() {
        val coordinatedPreferences = BlockingAuthCallbackPreferences(preferences)
        val repository = newRepository(coordinatedPreferences)
        val callbackExecutor = Executors.newSingleThreadExecutor()
        val clearThread = Thread(repository::clearCredentials)

        repository.saveNonceAndStateSync(nonce = "nonce-", state = "handoff-state")
        val callback =
            callbackExecutor.submit<AuthCallbackResult> {
                runBlocking {
                    repository
                        .saveAuthCallbackIfStateValid(
                            state = "handoff-state",
                            fragment = "fragment",
                        ).first()
                }
            }

        try {
            coordinatedPreferences.awaitCallbackApply()
            clearThread.start()
            awaitBlocked(clearThread)
            coordinatedPreferences.releaseCallbackApply()

            assertEquals(AuthCallbackResult.NEW_HANDOFF, callback.get(10, TimeUnit.SECONDS))
            clearThread.join(TimeUnit.SECONDS.toMillis(10))
            assertFalse(clearThread.isAlive)
            assertNull(repository.getTokenSync())
            assertNull(repository.getNonceSync())
            assertNull(repository.getStateSync())
            assertNull(preferences.getString("pendingAuthHandoffStateHash", null))
        } finally {
            coordinatedPreferences.releaseCallbackApply()
            callbackExecutor.shutdownNow()
            clearThread.join(TimeUnit.SECONDS.toMillis(10))
        }
    }

    @Test
    fun `acknowledging handoff rejects later callback replay`() =
        runBlocking {
            val repository = newRepository(preferences)
            completeAuth(repository, state = "handoff-state")

            assertFalse(repository.acknowledgeAuthCallbackHandoff("other-state"))
            assertTrue(repository.acknowledgeAuthCallbackHandoff("handoff-state"))
            assertFalse(repository.acknowledgeAuthCallbackHandoff("handoff-state"))

            val recreatedRepository = newRepository(preferences)
            assertEquals(
                AuthCallbackResult.INVALID,
                recreatedRepository
                    .saveAuthCallbackIfStateValid(
                        state = "handoff-state",
                        fragment = "replacement-fragment",
                    ).first(),
            )
            assertEquals("nonce-fragment", recreatedRepository.getTokenSync())
        }

    private fun newRepository(preferences: SharedPreferences): Repository = Repository(context, Dispatchers.Unconfined, preferences)

    private suspend fun completeAuth(
        repository: Repository,
        state: String,
    ) {
        repository.saveNonceAndStateSync(nonce = "nonce-", state = state)
        assertEquals(
            AuthCallbackResult.NEW_HANDOFF,
            repository
                .saveAuthCallbackIfStateValid(
                    state = state,
                    fragment = "fragment",
                ).first(),
        )
    }

    private fun awaitBlocked(thread: Thread) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
        while (thread.state != Thread.State.BLOCKED && thread.isAlive && System.nanoTime() < deadline) {
            Thread.yield()
        }

        assertEquals(Thread.State.BLOCKED, thread.state)
    }
}

private class RecordingSharedPreferences(
    private val delegate: SharedPreferences,
) : SharedPreferences by delegate {
    val appliedTransactions = mutableListOf<PreferenceTransaction>()

    override fun edit(): SharedPreferences.Editor =
        RecordingEditor(delegate.edit()) { transaction ->
            appliedTransactions += transaction
        }
}

private class RecordingEditor(
    private val delegate: SharedPreferences.Editor,
    private val onApply: (PreferenceTransaction) -> Unit,
) : SharedPreferences.Editor by delegate {
    private val stringKeys = mutableSetOf<String>()
    private val removedKeys = mutableSetOf<String>()

    override fun putString(
        key: String?,
        value: String?,
    ): SharedPreferences.Editor {
        key?.let { stringKeys += it }
        delegate.putString(key, value)
        return this
    }

    override fun remove(key: String?): SharedPreferences.Editor {
        key?.let { removedKeys += it }
        delegate.remove(key)
        return this
    }

    override fun apply() {
        onApply(PreferenceTransaction(putStringKeys = stringKeys.toSet(), removedKeys = removedKeys.toSet()))
        delegate.apply()
    }
}

private data class PreferenceTransaction(
    val putStringKeys: Set<String>,
    val removedKeys: Set<String>,
)

private class BlockingAuthCallbackPreferences(
    private val delegate: SharedPreferences,
) : SharedPreferences by delegate {
    private val callbackApplyStarted = CountDownLatch(1)
    private val callbackApplyRelease = CountDownLatch(1)

    override fun edit(): SharedPreferences.Editor {
        val editor = delegate.edit()
        val stringKeys = mutableSetOf<String>()
        return object : SharedPreferences.Editor by editor {
            override fun putString(
                key: String?,
                value: String?,
            ): SharedPreferences.Editor {
                key?.let { stringKeys += it }
                editor.putString(key, value)
                return this
            }

            override fun remove(key: String?): SharedPreferences.Editor {
                editor.remove(key)
                return this
            }

            override fun apply() {
                if ("token" in stringKeys) {
                    callbackApplyStarted.countDown()
                    check(callbackApplyRelease.await(10, TimeUnit.SECONDS))
                }
                editor.apply()
            }
        }
    }

    fun awaitCallbackApply() {
        check(callbackApplyStarted.await(10, TimeUnit.SECONDS))
    }

    fun releaseCallbackApply() {
        callbackApplyRelease.countDown()
    }
}
