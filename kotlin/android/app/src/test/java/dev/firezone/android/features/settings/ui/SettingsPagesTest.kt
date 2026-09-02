// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui

import dev.firezone.android.R
import org.junit.Assert.assertEquals
import org.junit.Test

class SettingsPagesTest {
    @Test
    fun `device trust page requires a configured certificate alias`() {
        assertEquals(
            listOf(R.id.settingsGeneral, R.id.settingsAdvanced, R.id.settingsLogs),
            settingsPages(hasConfiguredCertificateAlias = false).map { it.first },
        )
        assertEquals(
            listOf(R.id.settingsGeneral, R.id.settingsAdvanced, R.id.settingsDeviceTrust, R.id.settingsLogs),
            settingsPages(hasConfiguredCertificateAlias = true).map { it.first },
        )
    }
}
