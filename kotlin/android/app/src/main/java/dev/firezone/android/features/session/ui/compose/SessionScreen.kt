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
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import dev.firezone.android.R
import dev.firezone.android.core.data.Favorites
import dev.firezone.android.core.data.ResourceState
import dev.firezone.android.features.session.ui.ResourceViewModel
import dev.firezone.android.features.session.ui.isInternetResource
import dev.firezone.android.tunnel.model.ConnectedDevice
import dev.firezone.android.tunnel.model.Resource
import dev.firezone.android.tunnel.model.ResourceType
import dev.firezone.android.tunnel.model.StatusEnum
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.toImmutableList

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

    var selectedId by rememberSaveable { mutableStateOf<String?>(null) }
    var selectedDeviceId by rememberSaveable { mutableStateOf<String?>(null) }
    val selectedResource = remember(resources, selectedId) { resources.firstOrNull { it.id == selectedId } }
    val selectedDevice = remember(connectedDevices, selectedDeviceId) { connectedDevices.firstOrNull { it.id == selectedDeviceId } }

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
                        ResourceRow(resource = resource, onClick = { selectedId = resource.id })
                    }
                } else {
                    internetResource?.let { internet ->
                        item(key = "internet-${internet.id}") {
                            ResourceRow(resource = internet, onClick = { selectedId = internet.id })
                        }
                    }
                    collapsibleSection(
                        title = resourcesTitle,
                        entries = otherResources,
                        expanded = resourcesExpanded,
                        onToggle = { resourcesExpanded = !resourcesExpanded },
                        key = { "res-${it.id}" },
                    ) { resource ->
                        ResourceRow(resource = resource, onClick = { selectedId = resource.id })
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
                            ConnectedDeviceRow(device = device, onClick = { selectedDeviceId = device.id })
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
            onDismiss = { selectedId = null },
        )
    }

    selectedDevice?.let { device ->
        ConnectedDeviceDetailsSheet(
            device = device,
            onDismiss = { selectedDeviceId = null },
        )
    }
}

@Preview(showBackground = true, heightDp = 720)
@Composable
private fun SessionScreenPreview() {
    FirezoneTheme {
        SessionScreen(
            actorName = "Jane Doe",
            resources = sampleResources,
            connectedDevices = sampleConnectedDevices,
            favorites = Favorites(HashSet()),
            onToggleInternet = {},
            onAddFavorite = {},
            onRemoveFavorite = {},
            onSettings = {},
            onSignOut = {},
        )
    }
}

// The session screen starts with the Connected Devices section collapsed; this preview renders it
// expanded so the mocked device rows are visible without interacting.
@Preview(showBackground = true, heightDp = 480)
@Composable
private fun ConnectedDevicesSectionPreview() {
    FirezoneTheme {
        LazyColumn {
            collapsibleSection(
                title = "Connected Devices",
                entries = sampleConnectedDevices,
                expanded = true,
                onToggle = {},
                live = true,
                key = { it.id },
            ) { device ->
                ConnectedDeviceRow(device = device, onClick = {})
            }
        }
    }
}

// Mock data mirroring the Apple/Tauri tunnel mocks: a handful of devices on the 100.96.0.0/16
// tunnel range with assorted pool memberships (including one with no pools).
private val sampleConnectedDevices: ImmutableList<ConnectedDevice> =
    listOf(
        listOf("Engineering Pool"),
        listOf("Engineering Pool", "QA Pool"),
        listOf("QA Pool"),
        listOf("Sales Pool"),
        emptyList(),
    ).mapIndexed { index, pools ->
        ConnectedDevice(id = "client-${index + 1}", tunneledIpv4 = "100.96.0.${index + 1}", pools = pools)
    }.toImmutableList()

private val sampleResources: ImmutableList<ResourceViewModel> =
    listOf(
        Resource(
            type = ResourceType.Internet,
            id = "internet",
            address = null,
            addressDescription = null,
            sites = null,
            name = "Internet Resource",
            status = StatusEnum.ONLINE,
        ),
        Resource(
            type = ResourceType.DNS,
            id = "gitlab",
            address = "gitlab.example.com",
            addressDescription = null,
            sites = null,
            name = "GitLab",
            status = StatusEnum.ONLINE,
        ),
        Resource(
            type = ResourceType.CIDR,
            id = "prod-network",
            address = "10.0.0.0/24",
            addressDescription = null,
            sites = null,
            name = "Prod network",
            status = StatusEnum.ONLINE,
        ),
    ).map { ResourceViewModel(it, ResourceState.ENABLED) }.toImmutableList()
