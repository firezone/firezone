// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.session.ui.compose

import androidx.compose.ui.graphics.toArgb
import org.junit.Assert.assertEquals
import org.junit.Test

class FirezoneThemeTest {
    // Pins what the OKLCH conversion yields to what a browser paints the portal's own tokens as,
    // so the palette cannot drift away from the portal without saying so.
    @Test
    fun `portal tokens carry the colours the portal renders`() {
        listOf(
            Triple("brand", PortalBrand, 0xFFFF7605),
            Triple("brand secondary", PortalBrandSecondary, 0xFFFF9A47),
            Triple("brand tertiary", PortalBrandTertiary, 0xFFFFF1E5),
            Triple("brand hover", PortalBrandHover, 0xFFC25700),
            Triple("canvas", PortalCanvas, 0xFFEEF1F6),
            Triple("surface", PortalSurface, 0xFFFFFFFF),
            Triple("surface raised", PortalSurfaceRaised, 0xFFF7F9FC),
            Triple("border strong", PortalBorderStrong, 0x290F172A),
            Triple("text primary", PortalTextPrimary, 0xFF0F172A),
            Triple("text secondary", PortalTextSecondary, 0xFF475569),
            Triple("text tertiary", PortalTextTertiary, 0xFF6E8197),
            Triple("text inverse", PortalTextInverse, 0xFFF8FAFC),
            Triple("success", PortalSuccess, 0xFF16A34A),
            Triple("success light", PortalSuccessLight, 0xFFF0FDF4),
            Triple("success dark", PortalSuccessDark, 0xFF15803D),
            Triple("danger", PortalDanger, 0xFFDC2626),
            Triple("danger light", PortalDangerLight, 0xFFFEE2E2),
        ).forEach { (name, color, argb) ->
            assertEquals(name, argb.toInt(), color.toArgb())
        }
    }
}
