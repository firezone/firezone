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
import dev.firezone.android.tunnel.model.Site
import dev.firezone.android.tunnel.model.StatusEnum
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.toImmutableList

@Preview(showBackground = true, heightDp = 720)
@Composable
private fun SessionScreenPreview() {
    FirezoneTheme {
        SessionScreen(
            actorName = "Maya Ortiz",
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

// The same deployment the Apple mock scenario describes, so the galleries tell one story.
internal val sampleConnectedDevices: ImmutableList<ConnectedDevice> =
    listOf(
        ConnectedDevice(
            id = "a21c9663-4d0e-4f4a-a8fa-48790b1e5cef",
            name = "bench-controller-01",
            tunIpv4 = "100.64.3.18",
            tunIpv6 = "fd00:2021:1111::12",
            pools = listOf("Lab hardware", "Shared storage"),
        ),
        ConnectedDevice(
            id = "47e9e79b-e4eb-4444-af14-ec24c6a2afc2",
            name = "build-runner-02",
            tunIpv4 = "100.64.7.41",
            tunIpv6 = "fd00:2021:1111::29",
            pools = listOf("Build farm"),
        ),
        ConnectedDevice(
            id = "db8221d1-0277-4f05-b0a8-22b32a5a9a46",
            name = "build-runner-03",
            tunIpv4 = "100.64.7.42",
            tunIpv6 = "fd00:2021:1111::2a",
            pools = listOf("Build farm"),
        ),
        ConnectedDevice(
            id = "c951f7eb-6fa7-428b-aecf-10b654ecccf7",
            name = "design-nas",
            tunIpv4 = "100.64.11.5",
            tunIpv6 = "fd00:2021:1111::1f5",
            pools = listOf("Shared storage"),
        ),
        ConnectedDevice(
            id = "e8dc5d0d-93ac-4e1b-9532-866dda67ce5b",
            name = "vision-rig-01",
            tunIpv4 = "100.64.19.86",
            tunIpv6 = "fd00:2021:1111::3c1",
            pools = listOf("Lab hardware"),
        ),
    ).toImmutableList()

private val internetSite = Site(id = "1a4f0f4e-8f3f-4a2e-9b6d-3c5e7a1b2d40", name = "Internet")
private val sydneyOffice = Site(id = "917e9354-26b3-4704-867c-f84c8688d269", name = "Sydney Office")
private val productionCloud = Site(id = "3d7c1f5a-9e42-4b18-8c6f-2a0b5d8e7c31", name = "Production Cloud")
private val hardwareLab = Site(id = "5c8e2b91-7a34-4d6e-b25f-9f13c4a86d07", name = "Hardware Lab")

// A resource takes its status from its site, so resources sharing one share its status.
internal val sampleResources: ImmutableList<ResourceUiModel> =
    listOf(
        Resource(
            type = ResourceType.Internet,
            id = "425233f2-a1cb-4b7d-84f3-850367fa122a",
            address = null,
            addressDescription = null,
            sites = listOf(internetSite),
            name = "Internet Resource",
            status = StatusEnum.ONLINE,
        ),
        Resource(
            type = ResourceType.DNS,
            id = "0854dca1-2c5b-468a-be85-0eec2f02a211",
            address = "wiki.meridian.example",
            addressDescription = "https://wiki.meridian.example",
            sites = listOf(sydneyOffice),
            name = "Engineering wiki",
            status = StatusEnum.ONLINE,
        ),
        Resource(
            type = ResourceType.DNS,
            id = "92da16a4-0eb2-45c2-b882-8573aad73921",
            address = "git.meridian.example",
            addressDescription = null,
            sites = listOf(productionCloud),
            name = "Git server",
            status = StatusEnum.UNKNOWN,
        ),
        Resource(
            type = ResourceType.DNS,
            id = "ed3778b9-dd41-4312-b616-028b0bbaff1c",
            address = "*.svc.meridian.example",
            addressDescription = null,
            sites = listOf(productionCloud),
            name = "Internal services",
            status = StatusEnum.UNKNOWN,
        ),
        Resource(
            type = ResourceType.CIDR,
            id = "be575d17-b0b3-40c9-ac34-e1ec3064d75a",
            address = "192.0.2.0/24",
            addressDescription = null,
            sites = listOf(sydneyOffice),
            name = "Office network",
            status = StatusEnum.ONLINE,
        ),
        Resource(
            type = ResourceType.CIDR,
            id = "8900accd-e39d-4705-ac7c-2189c59b4a1c",
            address = "198.51.100.0/24",
            addressDescription = null,
            sites = listOf(productionCloud),
            name = "Production VPC",
            status = StatusEnum.UNKNOWN,
        ),
        Resource(
            type = ResourceType.CIDR,
            id = "6b15c815-cefc-4128-8ab0-d9d6a526bbc7",
            address = "203.0.113.0/24",
            addressDescription = null,
            sites = listOf(hardwareLab),
            name = "Robot test bench",
            status = StatusEnum.OFFLINE,
        ),
    ).map { ResourceUiModel(it, ResourceState.ENABLED) }.toImmutableList()
