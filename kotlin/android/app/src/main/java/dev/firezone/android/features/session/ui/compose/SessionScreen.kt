// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.session.ui.compose

import android.os.Parcelable
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
import dev.firezone.android.features.session.ui.isInternetResource
import dev.firezone.android.tunnel.model.ConnectedDevice
import kotlinx.collections.immutable.ImmutableList
import kotlinx.parcelize.Parcelize

private const val TAB_FAVORITES = 0
private const val TAB_ALL = 1

@Composable
fun SessionScreen(
    actorName: String?,
    resources: ImmutableList<ResourceViewModel>,
    connectedDevices: ImmutableList<ConnectedDevice>,
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

    val favoriteResources =
        remember(resources, favorites) {
            resources.filter { favorites.inner.contains(it.id) }
        }
    val internetResource = remember(resources) { resources.firstOrNull { it.isInternetResource() } }
    val otherResources = remember(resources) { resources.filter { !it.isInternetResource() } }

    var resourcesExpanded by rememberSaveable { mutableStateOf(true) }
    var devicesExpanded by rememberSaveable { mutableStateOf(false) }

    var selection by rememberSaveable { mutableStateOf<Selection?>(null) }
    val selectedResource =
        remember(resources, selection) {
            (selection as? Selection.Resource)?.let { sel -> resources.firstOrNull { it.id == sel.id } }
        }
    val selectedDevice =
        remember(connectedDevices, selection) {
            (selection as? Selection.Device)?.let { sel -> connectedDevices.firstOrNull { it.id == sel.id } }
        }

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

            val resourcesTitle = stringResource(R.string.resources)
            val connectedDevicesTitle = stringResource(R.string.connected_devices)

            LazyColumn(Modifier.weight(1f)) {
                if (hasFavorites && effectiveTab == TAB_FAVORITES) {
                    itemsIndexed(favoriteResources, key = { _, resource -> resource.id }) { index, resource ->
                        if (index > 0) HorizontalDivider()
                        ResourceRow(resource = resource, onClick = { selection = Selection.Resource(resource.id) })
                    }
                } else {
                    internetResource?.let { internet ->
                        item(key = "internet-${internet.id}") {
                            ResourceRow(resource = internet, onClick = { selection = Selection.Resource(internet.id) })
                        }
                    }
                    collapsibleSection(
                        title = resourcesTitle,
                        entries = otherResources,
                        expanded = resourcesExpanded,
                        onToggle = { resourcesExpanded = !resourcesExpanded },
                        key = { "res-${it.id}" },
                    ) { resource ->
                        ResourceRow(resource = resource, onClick = { selection = Selection.Resource(resource.id) })
                    }
                    if (connectedDevices.isNotEmpty()) {
                        collapsibleSection(
                            title = connectedDevicesTitle,
                            entries = connectedDevices,
                            expanded = devicesExpanded,
                            onToggle = { devicesExpanded = !devicesExpanded },
                            live = true,
                            key = { "dev-${it.id}" },
                        ) { device ->
                            ConnectedDeviceRow(device = device, onClick = { selection = Selection.Device(device.id) })
                        }
                    }
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
            onDismiss = { selection = null },
        )
    }

    selectedDevice?.let { device ->
        ConnectedDeviceDetailsSheet(
            device = device,
            onDismiss = { selection = null },
        )
    }
}

// At most one detail sheet is open at a time, so the selection is modelled as a sum type: a
// resource and a connected device can never be selected simultaneously.
private sealed interface Selection : Parcelable {
    @Parcelize data class Resource(
        val id: String,
    ) : Selection

    @Parcelize data class Device(
        val id: String,
    ) : Selection
}
