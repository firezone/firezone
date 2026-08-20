// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.permission.certificate.ui.compose

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import dev.firezone.android.R
import dev.firezone.android.features.session.ui.compose.FirezoneTheme

/**
 * Explains why the client certificate needs picking and offers to start the selection.
 */
@Composable
internal fun CertificatePermissionScreen(
    onSelectCertificate: () -> Unit,
    onSkip: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Scaffold(modifier = modifier) { innerPadding ->
        Column(
            Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Image(
                painter = painterResource(R.drawable.ic_firezone_logo),
                contentDescription = null,
                modifier = Modifier.size(120.dp),
            )
            Text(
                text = stringResource(R.string.app_short_name),
                style = MaterialTheme.typography.headlineSmall,
            )
            Text(
                text = stringResource(R.string.x509_selection_title),
                style = MaterialTheme.typography.titleLarge,
                textAlign = TextAlign.Center,
            )
            Text(
                text = stringResource(R.string.x509_selection_description),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
            Button(onClick = onSelectCertificate, modifier = Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.x509_select_certificate))
            }
            TextButton(onClick = onSkip, modifier = Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.skip))
            }
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
