// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core.data

import android.app.Application
import android.content.Context
import android.content.SharedPreferences
import kotlinx.coroutines.Dispatchers
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
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class)
class RepositoryCredentialsTest {
    private lateinit var context: Context
    private lateinit var preferences: SharedPreferences

    @Before
    fun setUp() {
        context = RuntimeEnvironment.getApplication()
        preferences = context.getSharedPreferences("repository-credentials", Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
    }

    @Test
    fun `repository removes persisted state from the legacy callback flow`() {
        preferences
            .edit()
            .putString("nonce", "legacy-nonce")
            .putString("state", "legacy-state")
            .putString("pendingAuthHandoffStateHash", "legacy-hash")
            .commit()

        newRepository(preferences)

        assertNull(preferences.getString("nonce", null))
        assertNull(preferences.getString("state", null))
        assertNull(preferences.getString("pendingAuthHandoffStateHash", null))
    }

    @Test
    fun `clearing credentials removes token and preserves device trust alias`() =
        runBlocking {
            val repository = newRepository(preferences)
            preferences.edit().putString("x509CertificateAlias", "device-trust-alias").commit()
            repository.saveToken("token").first()

            repository.clearCredentials()

            assertNull(repository.getTokenSync())
            assertEquals(
                "device-trust-alias",
                preferences.getString("x509CertificateAlias", null),
            )
        }

    @Test
    fun `clearing credentials waits for token persistence and wins`() {
        val blockingPreferences = BlockingTokenPreferences(preferences)
        val repository = newRepository(blockingPreferences)
        val executor = Executors.newSingleThreadExecutor()
        val clearThread = Thread(repository::clearCredentials)
        val save =
            executor.submit<Unit> {
                runBlocking { repository.saveToken("token").first() }
            }

        try {
            blockingPreferences.awaitTokenApply()
            clearThread.start()
            awaitBlocked(clearThread)
            blockingPreferences.releaseTokenApply()

            save.get(10, TimeUnit.SECONDS)
            clearThread.join(TimeUnit.SECONDS.toMillis(10))

            assertNull(repository.getTokenSync())
        } finally {
            blockingPreferences.releaseTokenApply()
            clearThread.join(TimeUnit.SECONDS.toMillis(10))
            executor.shutdownNow()
        }
    }

    private fun newRepository(sharedPreferences: SharedPreferences): Repository =
        Repository(context, Dispatchers.Unconfined, sharedPreferences)

    private fun awaitBlocked(thread: Thread) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
        while (thread.state != Thread.State.BLOCKED && thread.isAlive && System.nanoTime() < deadline) {
            Thread.yield()
        }

        assertEquals(Thread.State.BLOCKED, thread.state)
    }
}

private class BlockingTokenPreferences(
    private val delegate: SharedPreferences,
) : SharedPreferences by delegate {
    private val tokenApplyStarted = CountDownLatch(1)
    private val tokenApplyRelease = CountDownLatch(1)

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
            }
        }
    }

    fun awaitTokenApply() {
        check(tokenApplyStarted.await(10, TimeUnit.SECONDS))
    }

    fun releaseTokenApply() {
        tokenApplyRelease.countDown()
    }
}
