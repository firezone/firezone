// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui.compose

import org.junit.Assert.assertEquals
import org.junit.Test

class SettingsPagesTest {
    @Test
    fun `the device trust page appears only when asked for`() {
        assertEquals(
            listOf(SettingsPage.GENERAL, SettingsPage.LOGS),
            settingsPages(showDeviceTrust = false, showDeveloperSettings = false),
        )
        assertEquals(
            listOf(SettingsPage.GENERAL, SettingsPage.DEVICE_TRUST, SettingsPage.LOGS),
            settingsPages(showDeviceTrust = true, showDeveloperSettings = false),
        )
    }

    @Test
    fun `the developer page comes last and only when unlocked`() {
        assertEquals(
            listOf(SettingsPage.GENERAL, SettingsPage.LOGS, SettingsPage.DEVELOPER),
            settingsPages(showDeviceTrust = false, showDeveloperSettings = true),
        )
    }
}
