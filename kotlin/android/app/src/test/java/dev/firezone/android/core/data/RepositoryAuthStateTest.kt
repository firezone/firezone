// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core.data

import android.app.Application
import android.content.Context
import android.content.SharedPreferences
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class)
class RepositoryAuthStateTest {
    @Test
    fun `nonce and state are persisted in one transaction`() {
        val context = RuntimeEnvironment.getApplication()
        val delegate = context.getSharedPreferences("repository-auth-state", Context.MODE_PRIVATE)
        delegate.edit().clear().commit()
        val preferences = RecordingSharedPreferences(delegate)
        val repository = Repository(context, Dispatchers.Unconfined, preferences)

        repository.saveNonceAndStateSync(nonce = "new-nonce", state = "new-state")

        assertEquals(listOf(setOf("nonce", "state")), preferences.appliedStringKeys)
        assertEquals("new-nonce", repository.getNonceSync())
        assertEquals("new-state", repository.getStateSync())
    }
}

private class RecordingSharedPreferences(
    private val delegate: SharedPreferences,
) : SharedPreferences by delegate {
    val appliedStringKeys = mutableListOf<Set<String>>()

    override fun edit(): SharedPreferences.Editor =
        RecordingEditor(delegate.edit()) { keys ->
            appliedStringKeys += keys
        }
}

private class RecordingEditor(
    private val delegate: SharedPreferences.Editor,
    private val onApply: (Set<String>) -> Unit,
) : SharedPreferences.Editor by delegate {
    private val stringKeys = mutableSetOf<String>()

    override fun putString(
        key: String?,
        value: String?,
    ): SharedPreferences.Editor {
        key?.let { stringKeys += it }
        delegate.putString(key, value)
        return this
    }

    override fun apply() {
        onApply(stringKeys)
        delegate.apply()
    }
}
