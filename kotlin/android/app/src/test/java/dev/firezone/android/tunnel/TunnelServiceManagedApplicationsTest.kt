// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.tunnel

import android.os.Bundle
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class TunnelServiceManagedApplicationsTest {
    @Test
    fun `splits and trims the managed list`() {
        val restrictions = Bundle().apply { putString("allowedApplications", " com.a , com.b,,") }

        assertEquals(listOf("com.a", "com.b"), TunnelService.managedApplicationList(restrictions, "allowedApplications"))
    }

    @Test
    fun `missing key means no applications`() {
        assertEquals(emptyList<String>(), TunnelService.managedApplicationList(Bundle(), "allowedApplications"))
    }
}
