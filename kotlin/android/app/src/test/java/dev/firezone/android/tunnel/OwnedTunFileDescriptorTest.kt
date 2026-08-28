// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.tunnel

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class OwnedTunFileDescriptorTest {
    @Test
    fun `closing an undelivered descriptor releases it exactly once`() {
        val closed = mutableListOf<Int>()
        val descriptor = OwnedTunFileDescriptor(42) { fd -> closed += fd }

        descriptor.close()
        descriptor.close()

        assertEquals(listOf(42), closed)
    }

    @Test
    fun `successful transfer releases ownership to the consumer`() {
        val consumed = mutableListOf<Int>()
        val closed = mutableListOf<Int>()
        val descriptor = OwnedTunFileDescriptor(42) { fd -> closed += fd }

        descriptor.transferTo { fd -> consumed += fd }
        descriptor.close()

        assertEquals(listOf(42), consumed)
        assertEquals(emptyList<Int>(), closed)
    }

    @Test
    fun `failed transfer closes the descriptor`() {
        val closed = mutableListOf<Int>()
        val descriptor = OwnedTunFileDescriptor(42) { fd -> closed += fd }

        assertThrows(IllegalStateException::class.java) {
            descriptor.transferTo { error("Consumer failed") }
        }

        assertEquals(listOf(42), closed)
    }
}
