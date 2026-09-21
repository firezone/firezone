// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.session.ui.compose

import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.Composable
import androidx.compose.ui.tooling.preview.Preview
import dev.firezone.android.core.data.Favorites
import dev.firezone.android.core.data.ResourceState
import dev.firezone.android.features.session.ui.ResourceUiModel
import dev.firezone.android.tunnel.mockConnectedDevices
import dev.firezone.android.tunnel.mockResources
import dev.firezone.android.tunnel.model.ConnectedDevice
import dev.firezone.android.tunnel.model.toModel
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
            onEndSession = {},
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

// The deployment `MockFixtures` describes, converted the way the service converts a real one, so
// the galleries and the mock launch cannot drift apart.
internal val sampleResources: ImmutableList<ResourceUiModel> =
    mockResources.map { ResourceUiModel(it.toModel(), ResourceState.ENABLED) }.toImmutableList()

internal val sampleConnectedDevices: ImmutableList<ConnectedDevice> =
    mockConnectedDevices.map { it.toModel() }.toImmutableList()
