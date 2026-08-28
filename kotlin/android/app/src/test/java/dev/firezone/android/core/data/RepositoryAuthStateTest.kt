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
                    removedKeys = setOf("consumedAuthStateHash"),
                ),
            ),
            recordingPreferences.appliedTransactions,
        )
        assertEquals("new-nonce", repository.getNonceSync())
        assertEquals("new-state", repository.getStateSync())
    }

    @Test
    fun `callback persists credentials and consumed state in one transaction`() =
        runBlocking {
            val recordingPreferences = RecordingSharedPreferences(preferences)
            val repository = newRepository(recordingPreferences)
            repository.saveNonceAndStateSync(nonce = "nonce-", state = "consumed-state")
            recordingPreferences.appliedTransactions.clear()

            assertTrue(
                repository
                    .saveAuthCallbackIfStateValid(
                        state = "consumed-state",
                        fragment = "fragment",
                        accountSlug = "account",
                        actorName = "Actor",
                    ).first(),
            )

            assertEquals(
                listOf(
                    PreferenceTransaction(
                        putStringKeys = setOf("token", "accountSlug", "actorName", "consumedAuthStateHash"),
                        removedKeys = setOf("nonce", "state"),
                    ),
                ),
                recordingPreferences.appliedTransactions,
            )

            val recreatedRepository = newRepository(recordingPreferences)
            assertTrue(
                recreatedRepository
                    .saveAuthCallbackIfStateValid(
                        state = "consumed-state",
                        fragment = "replacement-fragment",
                        accountSlug = "replacement-account",
                        actorName = "Replacement Actor",
                    ).first(),
            )
            assertEquals(1, recordingPreferences.appliedTransactions.size)
            assertEquals("nonce-fragment", recreatedRepository.getTokenSync())
            assertEquals("account", recreatedRepository.getAccountSlug().first())
            assertEquals("Actor", recreatedRepository.getActorNameSync())
            assertNull(recreatedRepository.getNonceSync())
            assertNull(recreatedRepository.getStateSync())
        }

    @Test
    fun `new auth request invalidates consumed callback`() =
        runBlocking {
            val repository = newRepository(preferences)
            completeAuth(repository, state = "old-state")

            repository.saveNonceAndStateSync(nonce = "new-nonce-", state = "new-state")

            assertFalse(
                repository
                    .saveAuthCallbackIfStateValid(
                        state = "old-state",
                        fragment = "replacement-fragment",
                        accountSlug = "replacement-account",
                        actorName = "Replacement Actor",
                    ).first(),
            )
            assertEquals("nonce-fragment", repository.getTokenSync())
            assertEquals("account", repository.getAccountSlug().first())
            assertEquals("Actor", repository.getActorNameSync())
            assertEquals("new-nonce-", repository.getNonceSync())
            assertEquals("new-state", repository.getStateSync())
        }

    @Test
    fun `clearing token invalidates consumed callback`() =
        runBlocking {
            val repository = newRepository(preferences)
            completeAuth(repository, state = "consumed-state")

            repository.clearToken()

            val recreatedRepository = newRepository(preferences)
            assertFalse(
                recreatedRepository
                    .saveAuthCallbackIfStateValid(
                        state = "consumed-state",
                        fragment = "replacement-fragment",
                        accountSlug = "replacement-account",
                        actorName = "Replacement Actor",
                    ).first(),
            )
            assertNull(recreatedRepository.getTokenSync())
            assertEquals("account", recreatedRepository.getAccountSlug().first())
            assertEquals("Actor", recreatedRepository.getActorNameSync())
        }

    private fun newRepository(preferences: SharedPreferences): Repository =
        Repository(context, Dispatchers.Unconfined, preferences)

    private suspend fun completeAuth(
        repository: Repository,
        state: String,
    ) {
        repository.saveNonceAndStateSync(nonce = "nonce-", state = state)
        assertTrue(
            repository
                .saveAuthCallbackIfStateValid(
                    state = state,
                    fragment = "fragment",
                    accountSlug = "account",
                    actorName = "Actor",
                ).first(),
        )
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
        onApply(PreferenceTransaction(putStringKeys = stringKeys, removedKeys = removedKeys))
        delegate.apply()
    }
}

private data class PreferenceTransaction(
    val putStringKeys: Set<String>,
    val removedKeys: Set<String>,
)
