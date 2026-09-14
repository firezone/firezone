// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.session.ui.compose

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.unit.dp
import dev.firezone.android.R

@Composable
fun ProfileMenu(
    actorName: String,
    onSettings: () -> Unit,
    onEndSession: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var expanded by rememberSaveable { mutableStateOf(false) }

    Box(modifier) {
        ProfileButton(actorName = actorName, onClick = { expanded = true })

        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }, offset = DpOffset(x = (-4).dp, y = 0.dp)) {
            Text(
                text = actorName,
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
            )

            HorizontalDivider()

            DropdownMenuItem(
                text = { Text(stringResource(R.string.settings)) },
                onClick = {
                    expanded = false
                    onSettings()
                },
                leadingIcon = { Icon(painterResource(R.drawable.rounded_settings_black_24dp), contentDescription = null) },
                contentPadding = PaddingValues(horizontal = 16.dp),
            )
            DropdownMenuItem(
                text = { Text(stringResource(R.string.sign_out)) },
                onClick = {
                    expanded = false
                    onEndSession()
                },
                leadingIcon = { Icon(painterResource(R.drawable.rounded_logout_24dp), contentDescription = null) },
                contentPadding = PaddingValues(horizontal = 16.dp),
            )
        }
    }
}

@Composable
private fun ProfileButton(
    actorName: String,
    onClick: () -> Unit,
) {
    val label = stringResource(R.string.profile)

    IconButton(onClick = onClick, modifier = Modifier.semantics { contentDescription = label }) {
        Box(
            Modifier.size(32.dp).background(MaterialTheme.colorScheme.primary, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = actorName.take(1).uppercase(),
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onPrimary,
            )
        }
    }
}
