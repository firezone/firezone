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
    val colorScheme =
        lightColorScheme(
            primary = colorResource(R.color.primary_450),
            onPrimary = colorResource(R.color.neutral_50),
            surface = colorResource(R.color.neutral_50),
            onSurface = colorResource(R.color.neutral_900),
            onSurfaceVariant = colorResource(R.color.neutral_600),
        )

    val sourceSans =
        FontFamily(
            Font(R.font.source_sans_pro, FontWeight.Normal),
            Font(R.font.source_sans_pro_bold, FontWeight.Bold),
        )

    val baseTypography = Typography()
    val typography =
        baseTypography.copy(
            headlineSmall = baseTypography.headlineSmall.copy(fontFamily = sourceSans, fontWeight = FontWeight.Bold),
            titleLarge = baseTypography.titleLarge.copy(fontFamily = sourceSans, fontWeight = FontWeight.Bold),
            bodyLarge = baseTypography.bodyLarge.copy(fontFamily = sourceSans),
            bodyMedium = baseTypography.bodyMedium.copy(fontFamily = sourceSans),
            bodySmall = baseTypography.bodySmall.copy(fontFamily = sourceSans),
            labelSmall = baseTypography.labelSmall.copy(fontFamily = sourceSans),
        )

    MaterialTheme(colorScheme = colorScheme, typography = typography, content = content)
}
