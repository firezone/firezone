// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.session.ui.compose

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import dev.firezone.android.R

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FirezoneTopBar(
    modifier: Modifier = Modifier,
    actions: @Composable RowScope.() -> Unit,
) {
    TopAppBar(
        // M3 defaults the bar to `surface`, which seams against the canvas the page is painted with.
        colors =
            TopAppBarDefaults.topAppBarColors(
                containerColor = MaterialTheme.colorScheme.background,
            ),
        title = {
            Text(
                text = stringResource(R.string.app_short_name),
                style = MaterialTheme.typography.titleLarge,
            )
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
        actions = actions,
    )
}
