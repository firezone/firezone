// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui.compose

import org.junit.Assert.assertEquals
import org.junit.Test

class SettingsPagesTest {
    @Test
    fun `device trust page requires a configured certificate alias`() {
        assertEquals(
            listOf(SettingsPage.GENERAL, SettingsPage.ADVANCED, SettingsPage.LOGS),
            settingsPages(hasConfiguredCertificateAlias = false),
        )
        assertEquals(
            listOf(SettingsPage.GENERAL, SettingsPage.ADVANCED, SettingsPage.DEVICE_TRUST, SettingsPage.LOGS),
            settingsPages(hasConfiguredCertificateAlias = true),
        )
    }
}
