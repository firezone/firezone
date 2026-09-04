// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.permission.ui.compose

import androidx.annotation.StringRes
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.weight
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.colorResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import dev.firezone.android.R
import dev.firezone.android.features.session.ui.compose.FirezoneTopBar

/** Presents the explanation and actions shown before requesting an Android permission. */
@Composable
internal fun PermissionScreen(
    @StringRes title: Int,
    @StringRes description: Int,
    @StringRes actionLabel: Int,
    onAction: () -> Unit,
    modifier: Modifier = Modifier,
    onSkip: (() -> Unit)? = null,
) {
    Column(
        modifier =
            modifier
                .fillMaxSize()
                .background(MaterialTheme.colorScheme.background),
    ) {
        FirezoneTopBar(actions = {})

        Column(
            modifier =
                Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 32.dp, vertical = 16.dp),
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                text = stringResource(title),
                style = MaterialTheme.typography.headlineSmall,
                textAlign = TextAlign.Center,
            )
            Text(
                text = stringResource(description),
                style = MaterialTheme.typography.bodyLarge,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(top = 16.dp),
            )
            Button(
                onClick = onAction,
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
                Text(stringResource(actionLabel))
            }

            if (onSkip != null) {
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
    }
}
