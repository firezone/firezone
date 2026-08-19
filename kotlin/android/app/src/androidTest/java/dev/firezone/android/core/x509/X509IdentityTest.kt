// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core.x509

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Exercises the loader against a real KeyChain, which a JVM test cannot reach.
 */
@RunWith(AndroidJUnit4::class)
class X509IdentityTest {
    private val x509Identity = X509Identity(ApplicationProvider.getApplicationContext<Context>())

    @Test
    fun noConfiguredAliasLoadsNothing() {
        assertNull(x509Identity.load(null))
    }

    /**
     * The KeyChain reports an alias the caller may not use as absent rather than as an error,
     * so an alias that was never installed arrives here the same way as one an administrator
     * installed without granting this app access to it.
     */
    @Test
    fun anAliasTheKeyChainWillNotHandOverReportsMissingAccess() {
        val exception =
            assertThrows(X509IdentityException::class.java) {
                x509Identity.load("firezone-alias-that-was-never-installed")
            }

        assertTrue(
            "unexpected message: ${exception.message}",
            exception.message!!.contains("has not been granted access to it"),
        )
    }
}
