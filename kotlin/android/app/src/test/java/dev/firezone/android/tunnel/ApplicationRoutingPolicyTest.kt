// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.tunnel

import dev.firezone.android.core.data.model.ManagedConfiguration
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ApplicationRoutingPolicyTest {
    @Test
    fun `allow mode excludes notification packages`() {
        val policy =
            ManagedConfiguration(
                allowedApplications =
                    "com.example.allowed, com.google.android.gms, com.google.android.gsf, com.example.allowed",
            ).applicationRoutingPolicy()

        assertEquals(ApplicationRoutingMode.ALLOW, policy.mode)
        assertEquals(listOf("com.example.allowed"), policy.packageNames)
        assertFalse(policy.hasConflict)
    }

    @Test
    fun `disallow mode appends notification packages`() {
        val policy =
            ManagedConfiguration(
                disallowedApplications = "com.example.blocked, com.google.android.gms",
            ).applicationRoutingPolicy()

        assertEquals(ApplicationRoutingMode.DISALLOW, policy.mode)
        assertEquals(
            listOf(
                "com.example.blocked",
                "com.google.android.gms",
                "com.google.firebase.messaging",
                "com.google.android.gsf",
            ),
            policy.packageNames,
        )
    }

    @Test
    fun `conflicting lists use restrictive allow mode`() {
        val policy =
            ManagedConfiguration(
                allowedApplications = "com.example.allowed",
                disallowedApplications = "com.example.blocked",
            ).applicationRoutingPolicy()

        assertEquals(ApplicationRoutingMode.ALLOW, policy.mode)
        assertEquals(listOf("com.example.allowed"), policy.packageNames)
        assertTrue(policy.hasConflict)
    }

    @Test
    fun `allow mode requires at least one installed package`() {
        val attempted = mutableListOf<String>()
        val policy =
            ManagedConfiguration(
                allowedApplications = "com.example.missing, com.example.installed",
            ).applicationRoutingPolicy()

        val valid =
            policy.apply(
                addAllowed = { packageName ->
                    attempted += packageName
                    packageName == "com.example.installed"
                },
                addDisallowed = { error("Unexpected disallow application") },
            )

        assertTrue(valid)
        assertEquals(listOf("com.example.missing", "com.example.installed"), attempted)
        assertFalse(
            ManagedConfiguration(allowedApplications = "com.example.missing")
                .applicationRoutingPolicy()
                .apply(
                    addAllowed = { false },
                    addDisallowed = { error("Unexpected disallow application") },
                ),
        )
        assertFalse(
            ManagedConfiguration(allowedApplications = "com.google.android.gms")
                .applicationRoutingPolicy()
                .apply(
                    addAllowed = { error("Notification packages must not be allowed") },
                    addDisallowed = { error("Unexpected disallow application") },
                ),
        )
    }

    @Test
    fun `disallow mode tolerates unavailable packages`() {
        val attempted = mutableListOf<String>()
        val policy =
            ManagedConfiguration(disallowedApplications = "com.example.missing")
                .applicationRoutingPolicy()

        assertTrue(
            policy.apply(
                addAllowed = { error("Unexpected allow application") },
                addDisallowed = { packageName ->
                    attempted += packageName
                    false
                },
            ),
        )
        assertEquals(policy.packageNames, attempted)
    }
}
