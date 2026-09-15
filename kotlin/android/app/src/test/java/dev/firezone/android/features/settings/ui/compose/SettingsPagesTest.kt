// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui.compose

import org.junit.Assert.assertEquals
import org.junit.Test

class SettingsPagesTest {
    @Test
    fun `the device trust page appears only when asked for`() {
        assertEquals(
            listOf(SettingsPage.GENERAL, SettingsPage.ADVANCED, SettingsPage.LOGS),
            settingsPages(showDeviceTrust = false),
        )
        assertEquals(
            listOf(SettingsPage.GENERAL, SettingsPage.ADVANCED, SettingsPage.DEVICE_TRUST, SettingsPage.LOGS),
            settingsPages(showDeviceTrust = true),
        )
    }
}
