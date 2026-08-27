// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.auth.ui.compose

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import dev.firezone.android.R

@Composable
fun AuthScreen(modifier: Modifier = Modifier) {
    Column(
        modifier.fillMaxSize().padding(16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Image(
                painter = painterResource(R.drawable.ic_firezone_logo),
                contentDescription = null,
                modifier = Modifier.size(40.dp),
            )
            Text(
                text = stringResource(R.string.app_short_name),
                style = MaterialTheme.typography.headlineLarge,
                modifier = Modifier.padding(start = 8.dp),
            )
        }

        Spacer(Modifier.weight(1f))
        Text(stringResource(R.string.launching_auth_flow))
        Spacer(Modifier.weight(1f))
    }
}
