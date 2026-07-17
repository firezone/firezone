// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.session.ui.compose

import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.Composable
import androidx.compose.ui.tooling.preview.Preview
import dev.firezone.android.core.data.Favorites
import dev.firezone.android.core.data.ResourceState
import dev.firezone.android.features.session.ui.ResourceUiModel
import dev.firezone.android.tunnel.model.ConnectedDevice
import dev.firezone.android.tunnel.model.Resource
import dev.firezone.android.tunnel.model.ResourceType
import dev.firezone.android.tunnel.model.StatusEnum
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.toImmutableList

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

// Renders just the connected-device rows in isolation, so the mocked devices are visible without
// scrolling past the resources in the full screen preview.
@Preview(showBackground = true, heightDp = 320)
@Composable
private fun ConnectedDevicesSectionPreview() {
    FirezoneTheme {
        LazyColumn {
            items(sampleConnectedDevices, key = { it.id }) { device ->
                ConnectedDeviceRow(device = device, onClick = {})
            }
        }
    }
}

// Mock data mirroring the Apple/Tauri tunnel mocks: a handful of devices on the 100.96.0.0/16
// tunnel range with assorted pool memberships (including one with no pools).
internal val sampleConnectedDevices: ImmutableList<ConnectedDevice> =
    listOf(
        listOf("Engineering Pool"),
        listOf("Engineering Pool", "QA Pool"),
        listOf("QA Pool"),
        listOf("Sales Pool"),
        emptyList(),
    ).mapIndexed { index, pools ->
        ConnectedDevice(id = "client-${index + 1}", tunIpv4 = "100.96.0.${index + 1}", pools = pools)
    }.toImmutableList()

internal val sampleResources: ImmutableList<ResourceUiModel> =
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
    ).map { ResourceUiModel(it, ResourceState.ENABLED) }.toImmutableList()
