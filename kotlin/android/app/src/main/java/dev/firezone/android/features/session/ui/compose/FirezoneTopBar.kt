// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.session.ui.compose

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.firezone.android.R

// Pass a `null` subtitle where nobody is signed in; the bar then collapses to a single row.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FirezoneTopBar(
    subtitle: String?,
    onSettings: () -> Unit,
    modifier: Modifier = Modifier,
) {
    TopAppBar(
        // M3 defaults the bar to `surface`, which seams against the canvas the page is painted with.
        colors =
            TopAppBarDefaults.topAppBarColors(
                containerColor = MaterialTheme.colorScheme.background,
            ),
        // M3 has a `subtitle` slot but keeps it internal, so the two lines share the title slot.
        title = {
            Column {
                Text(
                    text = stringResource(R.string.app_short_name),
                    style = MaterialTheme.typography.titleLarge,
                )
                subtitle?.let {
                    Text(
                        text = it,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        },
        modifier = modifier,
        navigationIcon = {
            Image(
                painter = painterResource(R.drawable.ic_firezone_logo),
                contentDescription = null,
                // The slot already insets by 4dp, so this lands the mark on the standard 16dp margin.
                modifier = Modifier.padding(start = 12.dp).size(32.dp),
            )
        },
        actions = {
            IconButton(onClick = onSettings) {
                Icon(
                    painter = painterResource(R.drawable.rounded_settings_black_24dp),
                    contentDescription = stringResource(R.string.settings),
                )
            }
        },
    )
}
