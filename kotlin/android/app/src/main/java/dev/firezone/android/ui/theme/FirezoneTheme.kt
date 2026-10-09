// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import dev.firezone.android.R
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.pow
import kotlin.math.sin

@Composable
fun FirezoneTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = FirezoneColorScheme,
        typography = FirezoneTypography,
        content = content,
    )
}

/** Converts one of the portal's OKLCH colours to the sRGB that Android paints with. */
internal fun oklch(
    l: Float,
    c: Float,
    h: Float,
    alpha: Float = 1f,
): Color {
    val hue = h * PI.toFloat() / 180f
    val a = c * cos(hue)
    val b = c * sin(hue)
    val lightness = l / 100f

    val long = (lightness + 0.3963377774f * a + 0.2158037573f * b).pow(3)
    val medium = (lightness - 0.1055613458f * a - 0.0638541728f * b).pow(3)
    val short = (lightness - 0.0894841775f * a - 1.2914855480f * b).pow(3)

    return Color(
        red = gammaEncode(4.0767416621f * long - 3.3077115913f * medium + 0.2309699292f * short),
        green = gammaEncode(-1.2684380046f * long + 2.6097574011f * medium - 0.3413193965f * short),
        blue = gammaEncode(-0.0041960863f * long - 0.7034186147f * medium + 1.7076147010f * short),
        alpha = alpha,
    )
}

/** sRGB's transfer function, which the linear channels the conversion above yields still need. */
private fun gammaEncode(channel: Float): Float {
    val clamped = channel.coerceIn(0f, 1f)

    return if (clamped > 0.0031308f) 1.055f * clamped.pow(1f / 2.4f) - 0.055f else 12.92f * clamped
}

// The admin portal's semantic tokens, carrying the OKLCH values `elixir/assets/css/main.css`
// defines them with so the two can be compared by searching for the same numbers.
internal val PortalBrand = oklch(71.74f, 0.192f, 48.75f)
internal val PortalBrandSecondary = oklch(77.69f, 0.154f, 56.87f)
internal val PortalBrandTertiary = oklch(96.59f, 0.022f, 63.21f)
internal val PortalBrandHover = oklch(58.23f, 0.1574f, 48.48f)

internal val PortalCanvas = oklch(95.73f, 0.0074f, 260.73f)
internal val PortalSurface = oklch(100f, 0f, 0f)
internal val PortalSurfaceRaised = oklch(98.14f, 0.0045f, 258.32f)
internal val PortalBorderStrong = oklch(20.77f, 0.0398f, 265.75f, alpha = 0.16f)

internal val PortalTextPrimary = oklch(20.77f, 0.0398f, 265.75f)
internal val PortalTextSecondary = oklch(44.55f, 0.0374f, 257.28f)
internal val PortalTextTertiary = oklch(59.6f, 0.0404f, 252.26f)
internal val PortalTextInverse = oklch(98.42f, 0.0034f, 247.86f)

internal val PortalSuccess = oklch(62.71f, 0.1699f, 149.21f)

// The portal has no opaque success background or dark success text of its own, so these take the
// toast and badge colours it paints those with.
internal val PortalSuccessLight = oklch(98.19f, 0.0181f, 155.83f)
internal val PortalSuccessDark = oklch(52.73f, 0.1371f, 150.07f)

internal val PortalDanger = oklch(57.71f, 0.2152f, 27.33f)
internal val PortalDangerLight = oklch(93.56f, 0.0309f, 17.72f)

// Every role is spelled out: whatever we leave to Material 3 falls back to its baseline purple.
private val FirezoneColorScheme =
    lightColorScheme(
        primary = PortalBrand,
        onPrimary = PortalSurface,
        primaryContainer = PortalBrandTertiary,
        onPrimaryContainer = PortalBrandHover,
        inversePrimary = PortalBrandSecondary,
        // The portal marks the selected navigation entry with the brand, not the accent
        // (`bg-brand-muted text-brand` in `navigation_components.ex`), and Material routes
        // that selection through the secondary roles.
        secondary = PortalBrandHover,
        onSecondary = PortalSurface,
        secondaryContainer = PortalBrandTertiary,
        onSecondaryContainer = PortalBrandHover,
        // Repurposed as the "live" status accent (e.g. the connected-device pulse dot).
        tertiary = PortalSuccess,
        onTertiary = PortalSurface,
        tertiaryContainer = PortalSuccessLight,
        onTertiaryContainer = PortalSuccessDark,
        background = PortalCanvas,
        onBackground = PortalTextPrimary,
        surface = PortalSurface,
        onSurface = PortalTextPrimary,
        surfaceVariant = PortalSurfaceRaised,
        onSurfaceVariant = PortalTextSecondary,
        surfaceTint = PortalBrand,
        surfaceDim = PortalCanvas,
        surfaceBright = PortalSurface,
        surfaceContainerLowest = PortalSurface,
        surfaceContainerLow = PortalSurface,
        surfaceContainer = PortalSurfaceRaised,
        surfaceContainerHigh = PortalSurfaceRaised,
        surfaceContainerHighest = PortalSurfaceRaised,
        inverseSurface = PortalTextPrimary,
        inverseOnSurface = PortalTextInverse,
        outline = PortalTextTertiary,
        outlineVariant = PortalBorderStrong,
        scrim = PortalTextPrimary,
        error = PortalDanger,
        onError = PortalSurface,
        errorContainer = PortalDangerLight,
        onErrorContainer = PortalDanger,
        primaryFixed = PortalBrandTertiary,
        primaryFixedDim = PortalBrandSecondary,
        onPrimaryFixed = PortalTextPrimary,
        onPrimaryFixedVariant = PortalBrandHover,
        secondaryFixed = PortalBrandTertiary,
        secondaryFixedDim = PortalBrandSecondary,
        onSecondaryFixed = PortalTextPrimary,
        onSecondaryFixedVariant = PortalBrandHover,
        tertiaryFixed = PortalSuccessLight,
        tertiaryFixedDim = PortalSuccess,
        onTertiaryFixed = PortalTextPrimary,
        onTertiaryFixedVariant = PortalSuccessDark,
    )

private val SourceSans =
    FontFamily(
        Font(R.font.source_sans_pro, FontWeight.Normal),
        Font(R.font.source_sans_pro_bold, FontWeight.Bold),
    )

private val FirezoneTypography =
    Typography().let { base ->
        base.copy(
            displaySmall = base.displaySmall.copy(fontFamily = SourceSans, fontWeight = FontWeight.Bold),
            headlineLarge = base.headlineLarge.copy(fontFamily = SourceSans, fontWeight = FontWeight.Bold),
            headlineSmall = base.headlineSmall.copy(fontFamily = SourceSans, fontWeight = FontWeight.Bold),
            titleLarge = base.titleLarge.copy(fontFamily = SourceSans, fontWeight = FontWeight.Bold),
            bodyLarge = base.bodyLarge.copy(fontFamily = SourceSans),
            bodyMedium = base.bodyMedium.copy(fontFamily = SourceSans),
            bodySmall = base.bodySmall.copy(fontFamily = SourceSans),
            labelSmall = base.labelSmall.copy(fontFamily = SourceSans),
        )
    }
