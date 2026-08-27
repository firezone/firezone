// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.session.ui.compose

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.res.colorResource
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import dev.firezone.android.R

@Composable
fun FirezoneTheme(content: @Composable () -> Unit) {
    // Every role is spelled out: whatever we leave to Material 3 falls back to its baseline
    // purple. The values come from the admin portal's semantic tokens (see `portal_*` in
    // `colors.xml`), so brand orange drives actions, the slate ramp drives text and the
    // canvas / surface / raised trio drives backgrounds, exactly as the portal renders them.
    val colorScheme =
        lightColorScheme(
            primary = colorResource(R.color.portal_brand),
            onPrimary = colorResource(R.color.portal_surface),
            primaryContainer = colorResource(R.color.portal_brand_tertiary),
            onPrimaryContainer = colorResource(R.color.portal_brand_hover),
            inversePrimary = colorResource(R.color.portal_brand_secondary),
            // The portal marks the selected navigation entry with the brand, not the accent
            // (`bg-brand-muted text-brand` in `navigation_components.ex`), and Material routes
            // that selection through the secondary roles.
            secondary = colorResource(R.color.portal_brand_hover),
            onSecondary = colorResource(R.color.portal_surface),
            secondaryContainer = colorResource(R.color.portal_brand_tertiary),
            onSecondaryContainer = colorResource(R.color.portal_brand_hover),
            // Repurposed as the "live" status accent (e.g. the connected-device pulse dot).
            tertiary = colorResource(R.color.portal_success),
            onTertiary = colorResource(R.color.portal_surface),
            tertiaryContainer = colorResource(R.color.portal_success_light),
            onTertiaryContainer = colorResource(R.color.portal_success_dark),
            background = colorResource(R.color.portal_canvas),
            onBackground = colorResource(R.color.portal_text_primary),
            surface = colorResource(R.color.portal_surface),
            onSurface = colorResource(R.color.portal_text_primary),
            surfaceVariant = colorResource(R.color.portal_surface_raised),
            onSurfaceVariant = colorResource(R.color.portal_text_secondary),
            surfaceTint = colorResource(R.color.portal_brand),
            surfaceDim = colorResource(R.color.portal_canvas),
            surfaceBright = colorResource(R.color.portal_surface),
            surfaceContainerLowest = colorResource(R.color.portal_surface),
            surfaceContainerLow = colorResource(R.color.portal_surface),
            surfaceContainer = colorResource(R.color.portal_surface_raised),
            surfaceContainerHigh = colorResource(R.color.portal_surface_raised),
            surfaceContainerHighest = colorResource(R.color.portal_surface_raised),
            inverseSurface = colorResource(R.color.portal_text_primary),
            inverseOnSurface = colorResource(R.color.portal_text_inverse),
            outline = colorResource(R.color.portal_text_tertiary),
            outlineVariant = colorResource(R.color.portal_border_strong),
            scrim = colorResource(R.color.portal_text_primary),
            error = colorResource(R.color.portal_danger),
            onError = colorResource(R.color.portal_surface),
            errorContainer = colorResource(R.color.portal_danger_light),
            onErrorContainer = colorResource(R.color.portal_danger),
            primaryFixed = colorResource(R.color.portal_brand_tertiary),
            primaryFixedDim = colorResource(R.color.portal_brand_secondary),
            onPrimaryFixed = colorResource(R.color.portal_text_primary),
            onPrimaryFixedVariant = colorResource(R.color.portal_brand_hover),
            secondaryFixed = colorResource(R.color.portal_brand_tertiary),
            secondaryFixedDim = colorResource(R.color.portal_brand_secondary),
            onSecondaryFixed = colorResource(R.color.portal_text_primary),
            onSecondaryFixedVariant = colorResource(R.color.portal_brand_hover),
            tertiaryFixed = colorResource(R.color.portal_success_light),
            tertiaryFixedDim = colorResource(R.color.portal_success),
            onTertiaryFixed = colorResource(R.color.portal_text_primary),
            onTertiaryFixedVariant = colorResource(R.color.portal_success_dark),
        )

    MaterialTheme(colorScheme = colorScheme, typography = FirezoneTypography, content = content)
}

private val SourceSans =
    FontFamily(
        Font(R.font.source_sans_pro, FontWeight.Normal),
        Font(R.font.source_sans_pro_bold, FontWeight.Bold),
    )

private val FirezoneTypography =
    Typography().let { base ->
        base.copy(
            headlineSmall = base.headlineSmall.copy(fontFamily = SourceSans, fontWeight = FontWeight.Bold),
            titleLarge = base.titleLarge.copy(fontFamily = SourceSans, fontWeight = FontWeight.Bold),
            bodyLarge = base.bodyLarge.copy(fontFamily = SourceSans),
            bodyMedium = base.bodyMedium.copy(fontFamily = SourceSans),
            bodySmall = base.bodySmall.copy(fontFamily = SourceSans),
            labelSmall = base.labelSmall.copy(fontFamily = SourceSans),
        )
    }
