// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui

import dev.firezone.android.R
import org.junit.Assert.assertEquals
import org.junit.Test

class SettingsPagesTest {
    @Test
    fun `the device trust page appears only when asked for`() {
        assertEquals(
            listOf(R.id.settingsGeneral, R.id.settingsAdvanced, R.id.settingsLogs),
            settingsPages(showDeviceTrust = false).map { it.first },
        )
        assertEquals(
            listOf(R.id.settingsGeneral, R.id.settingsAdvanced, R.id.settingsDeviceTrust, R.id.settingsLogs),
            settingsPages(showDeviceTrust = true).map { it.first },
        )
    }
}
