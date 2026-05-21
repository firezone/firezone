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
