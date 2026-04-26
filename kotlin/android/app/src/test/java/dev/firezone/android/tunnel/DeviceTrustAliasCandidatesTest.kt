// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.tunnel

import org.junit.Assert.assertEquals
import org.junit.Test

class DeviceTrustAliasCandidatesTest {
    @Test
    fun returnsCachedAliasBeforeManagedAndConventionalAlias() {
        assertEquals(
            listOf("user-selected-alias", "mdm-generated-alias", DEFAULT_DEVICE_TRUST_CERTIFICATE_ALIAS),
            deviceTrustCandidateAliases(
                managedAlias = "mdm-generated-alias",
                cachedAlias = "user-selected-alias",
            ),
        )
    }

    @Test
    fun returnsManagedAliasBeforeConventionalAlias() {
        assertEquals(
            listOf("mdm-generated-alias", DEFAULT_DEVICE_TRUST_CERTIFICATE_ALIAS),
            deviceTrustCandidateAliases(
                managedAlias = "mdm-generated-alias",
                cachedAlias = null,
            ),
        )
    }

    @Test
    fun deDuplicatesConventionalAliasWhenManagedAliasMatches() {
        assertEquals(
            listOf(DEFAULT_DEVICE_TRUST_CERTIFICATE_ALIAS),
            deviceTrustCandidateAliases(
                managedAlias = DEFAULT_DEVICE_TRUST_CERTIFICATE_ALIAS,
                cachedAlias = null,
            ),
        )
    }

    @Test
    fun prefersCachedAliasForChooser() {
        assertEquals(
            "user-selected-alias",
            preferredDeviceTrustCertificateAlias(
                managedAlias = "mdm-generated-alias",
                cachedAlias = "user-selected-alias",
            ),
        )
    }
}
