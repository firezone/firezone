// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.permission.certificate.ui.compose

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.res.colorResource
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.firezone.android.R
import dev.firezone.android.features.session.ui.compose.FirezoneTheme

/**
 * Explains why the client certificate needs picking and offers to start the selection.
 *
 * Styled and arranged like the sibling permission screens: the logo leads, the wordmark sits
 * centered between it and the content block, and the block itself is centered in the full
 * height, with the sibling layouts' text styles, spacing and button colors.
 */
@Composable
internal fun CertificatePermissionScreen(
    onSelectCertificate: () -> Unit,
    onSkip: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Scaffold(modifier = modifier) { innerPadding ->
        Layout(
            content = {
                Image(
                    painter = painterResource(R.drawable.ic_firezone_logo),
                    contentDescription = null,
                    modifier = Modifier.size(120.dp),
                )
                Text(
                    text = stringResource(R.string.app_short_name),
                    fontFamily = FontFamily(Font(R.font.manrope_bold, FontWeight.Bold)),
                    fontSize = 48.sp,
                )
                ContentBlock(onSelectCertificate = onSelectCertificate, onSkip = onSkip)
            },
            modifier =
                Modifier
                    .fillMaxSize()
                    .padding(innerPadding)
                    .padding(16.dp),
        ) { measurables, constraints ->
            val loose = constraints.copy(minWidth = 0, minHeight = 0)
            val logo = measurables[0].measure(loose)
            val wordmark = measurables[1].measure(loose)
            val block = measurables[2].measure(constraints.copy(minHeight = 0))

            layout(constraints.maxWidth, constraints.maxHeight) {
                val logoTop = 8.dp.roundToPx()
                logo.place((constraints.maxWidth - logo.width) / 2, logoTop)

                val blockTop = (constraints.maxHeight - block.height) / 2
                block.place((constraints.maxWidth - block.width) / 2, blockTop)

                val gapCenter = (logoTop + logo.height + blockTop) / 2
                wordmark.place(
                    (constraints.maxWidth - wordmark.width) / 2,
                    gapCenter - wordmark.height / 2,
                )
            }
        }
    }
}

@Composable
private fun ContentBlock(
    onSelectCertificate: () -> Unit,
    onSkip: () -> Unit,
) {
    Column(
        Modifier
            .fillMaxWidth()
            .padding(16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            text = stringResource(R.string.x509_selection_title),
            fontFamily = FontFamily(Font(R.font.source_sans_pro)),
            fontSize = 24.sp,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(top = 36.dp),
        )
        Text(
            text = stringResource(R.string.x509_selection_description),
            style = MaterialTheme.typography.bodyLarge.copy(lineHeight = TextUnit.Unspecified),
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(top = 16.dp),
        )
        Button(
            onClick = onSelectCertificate,
            colors =
                ButtonDefaults.buttonColors(
                    containerColor = colorResource(R.color.neutral_900),
                    contentColor = Color.White,
                ),
            modifier =
                Modifier
                    .padding(top = 24.dp)
                    .fillMaxWidth(),
        ) {
            Text(stringResource(R.string.x509_select_certificate))
        }
        TextButton(
            onClick = onSkip,
            colors = ButtonDefaults.textButtonColors(contentColor = colorResource(R.color.neutral_900)),
            modifier =
                Modifier
                    .padding(top = 8.dp)
                    .fillMaxWidth(),
        ) {
            Text(stringResource(R.string.skip))
        }
    }
}

@Preview
@Composable
private fun CertificatePermissionScreenPreview() {
    FirezoneTheme {
        CertificatePermissionScreen(
            onSelectCertificate = {},
            onSkip = {},
        )
    }
}
