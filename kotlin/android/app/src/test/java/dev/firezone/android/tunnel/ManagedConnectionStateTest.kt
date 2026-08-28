// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.tunnel

import dev.firezone.android.core.data.model.ManagedConfiguration
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class ManagedConnectionStateTest {
    @Test
    fun `only one connection owns session setup`() {
        val state = ManagedConnectionState<Any>()
        val firstOwner = Any()
        val startRequest = state.requestStart()

        assertEquals(ConnectionClaim.Started(firstOwner), state.claim(startRequest) { firstOwner })
        assertEquals(ConnectionClaim.Existing(firstOwner), state.claim(startRequest) { Any() })
    }

    @Test
    fun `managed identity change during setup restarts with latest configuration`() {
        val state = ManagedConnectionState<Any>()
        val firstOwner = Any()
        val secondOwner = Any()
        val initialConfiguration = ManagedConfiguration(token = "first-token")
        val replacementConfiguration = ManagedConfiguration(token = "second-token")

        state.apply(initialConfiguration)
        state.claim(state.requestStart()) { firstOwner }

        val update = state.apply(replacementConfiguration)!!
        assertTrue(update.requiresReconnect)
        assertSame(firstOwner, update.owner)

        var restartedWith: ManagedConfiguration? = null
        val completion =
            state.complete(firstOwner) { configuration ->
                restartedWith = configuration
                secondOwner
            }

        assertEquals(ConnectionCompletion.Restarted(secondOwner), completion)
        assertEquals(replacementConfiguration, restartedWith)
        assertSame(secondOwner, state.owner())
    }

    @Test
    fun `explicit disconnect wins over subsequent managed changes`() {
        val state = ManagedConnectionState<Any>()
        val owner = Any()

        state.apply(ManagedConfiguration(token = "first-token"))
        state.claim(state.requestStart()) { owner }
        state.apply(ManagedConfiguration(token = "second-token"))
        state.disconnect()
        state.apply(ManagedConfiguration(token = "third-token"))

        assertEquals(
            ConnectionCompletion.Stopped,
            state.complete(owner) { Any() },
        )
        assertNull(state.owner())
    }

    @Test
    fun `new start request prevents an old completion from stopping the service`() {
        val state = ManagedConnectionState<Any>()
        val firstOwner = Any()

        state.claim(state.requestStart()) { firstOwner }
        state.beginCompletion(firstOwner)
        assertEquals(
            ConnectionCompletion.Stopped,
            state.complete(firstOwner) { Any() },
        )

        val startRequest = state.requestStart()
        var stopped = false

        assertFalse(state.stopIfIdle { stopped = true })
        assertFalse(stopped)
        assertTrue(state.claim(startRequest) { Any() } is ConnectionClaim.Started)
    }

    @Test
    fun `new start request during completion starts a replacement owner`() {
        val state = ManagedConnectionState<Any>()
        val firstOwner = Any()
        val replacementOwner = Any()

        state.claim(state.requestStart()) { firstOwner }
        state.beginCompletion(firstOwner)
        state.requestStart()

        assertEquals(
            ConnectionCompletion.Restarted(replacementOwner),
            state.complete(firstOwner) { replacementOwner },
        )
    }

    @Test
    fun `older failed start cannot cancel a newer request`() {
        val state = ManagedConnectionState<Any>()
        val firstRequest = state.requestStart()
        val secondRequest = state.requestStart()

        assertEquals(ConnectionClaim.Unavailable, state.claim(firstRequest) { null })
        assertFalse(state.stopIfIdle {})
        assertTrue(state.claim(secondRequest) { Any() } is ConnectionClaim.Started)
    }
}
