// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.session.ui.compose

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LeadingIconTab
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.TabRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import dev.firezone.android.R
import dev.firezone.android.core.data.Favorites
import dev.firezone.android.features.session.ui.ResourceViewModel
import kotlinx.collections.immutable.ImmutableList

private const val TAB_FAVORITES = 0
private const val TAB_ALL = 1

@Composable
fun SessionScreen(
    actorName: String?,
    resources: ImmutableList<ResourceViewModel>,
    favorites: Favorites,
    onToggleInternet: () -> Unit,
    onAddFavorite: (String) -> Unit,
    onRemoveFavorite: (String) -> Unit,
    onSettings: () -> Unit,
    onSignOut: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val hasFavorites = favorites.inner.isNotEmpty()
    var selectedTab by rememberSaveable { mutableIntStateOf(TAB_FAVORITES) }
    // No favorites -> always show "All", and latch the selection there so that adding the
    // first favorite doesn't unexpectedly switch the user onto the Favorites tab.
    LaunchedEffect(hasFavorites) {
        if (!hasFavorites) selectedTab = TAB_ALL
    }
    val effectiveTab = if (!hasFavorites) TAB_ALL else selectedTab

    val displayed =
        remember(resources, favorites, effectiveTab) {
            if (hasFavorites && effectiveTab == TAB_FAVORITES) {
                resources.filter { favorites.inner.contains(it.id) }
            } else {
                resources
            }
        }

    var selectedId by rememberSaveable { mutableStateOf<String?>(null) }
    val selectedResource = remember(resources, selectedId) { resources.firstOrNull { it.id == selectedId } }

    Scaffold(modifier = modifier) { innerPadding ->
        Column(Modifier.fillMaxSize().padding(innerPadding).padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Image(
                    painter = painterResource(R.drawable.ic_firezone_logo),
                    contentDescription = null,
                    modifier = Modifier.size(32.dp),
                )
                Text(
                    text = stringResource(R.string.app_short_name),
                    style = MaterialTheme.typography.headlineSmall,
                    modifier = Modifier.padding(start = 8.dp),
                )
                Spacer(Modifier.weight(1f))
                actorName?.let { Text(text = it, style = MaterialTheme.typography.bodySmall) }
            }

            Text(
                text = stringResource(R.string.resources),
                style = MaterialTheme.typography.headlineSmall,
                modifier = Modifier.padding(top = 24.dp, bottom = 8.dp),
            )

            if (hasFavorites) {
                TabRow(selectedTabIndex = effectiveTab) {
                    LeadingIconTab(
                        selected = effectiveTab == TAB_FAVORITES,
                        onClick = { selectedTab = TAB_FAVORITES },
                        text = { Text(stringResource(R.string.resources_favorites)) },
                        icon = { Icon(painterResource(R.drawable.baseline_star_24), contentDescription = null) },
                    )
                    LeadingIconTab(
                        selected = effectiveTab == TAB_ALL,
                        onClick = { selectedTab = TAB_ALL },
                        text = { Text(stringResource(R.string.resources_all)) },
                        icon = { Icon(painterResource(R.drawable.all_resources), contentDescription = null) },
                    )
                }
            }

            LazyColumn(Modifier.weight(1f)) {
                itemsIndexed(displayed, key = { _, resource -> resource.id }) { index, resource ->
                    if (index > 0) HorizontalDivider()
                    ResourceRow(resource = resource, onClick = { selectedId = resource.id })
                }
            }

            Row(
                Modifier.fillMaxWidth().padding(top = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                OutlinedButton(onClick = onSettings, modifier = Modifier.weight(1f)) {
                    Text(stringResource(R.string.settings))
                }
                Button(onClick = onSignOut, modifier = Modifier.weight(1f)) {
                    Text(stringResource(R.string.sign_out))
                }
            }
        }
    }

    selectedResource?.let { resource ->
        ResourceDetailsSheet(
            resource = resource,
            isFavorite = favorites.inner.contains(resource.id),
            onAddFavorite = { onAddFavorite(resource.id) },
            onRemoveFavorite = { onRemoveFavorite(resource.id) },
            onToggleInternet = onToggleInternet,
            onDismiss = { selectedId = null },
        )
    }
}
