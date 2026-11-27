// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.auth

import org.junit.Assert.assertEquals
import org.junit.Test

class NonceHashTest {
    @Test
    fun hashesTheNonceAsLowercaseHexSha256() {
        assertEquals(
            "259c3342c0017c48a4b145571be0622790a6a9ad98c5e63dbad74256232d48ca",
            nonceHash("some_nonce"),
        )
    }
}
