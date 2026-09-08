// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.tunnel

import uniffi.connlib.CidrResource
import uniffi.connlib.ConnectedDevice
import uniffi.connlib.DnsResource
import uniffi.connlib.InternetResource
import uniffi.connlib.Resource
import uniffi.connlib.ResourceStatus
import uniffi.connlib.Site

// The deployment the screenshot fixtures describe, in the shape connlib reports it. The mock
// session serves these to a debug launch and the end-to-end tests assert against them, so the
// galleries, the harness and the tests all tell one story.
const val MOCK_ACTOR_NAME = "Jane Doe"
const val MOCK_ACCOUNT_SLUG = "example-corp"

private val internetSite = Site(id = "1a4f0f4e-8f3f-4a2e-9b6d-3c5e7a1b2d40", name = "Internet")
private val sydneyOffice = Site(id = "917e9354-26b3-4704-867c-f84c8688d269", name = "Sydney Office")
private val productionCloud = Site(id = "3d7c1f5a-9e42-4b18-8c6f-2a0b5d8e7c31", name = "Production Cloud")
private val hardwareLab = Site(id = "5c8e2b91-7a34-4d6e-b25f-9f13c4a86d07", name = "Hardware Lab")

val internetResource =
    Resource.Internet(
        InternetResource(
            id = "425233f2-a1cb-4b7d-84f3-850367fa122a",
            name = "Internet Resource",
            sites = listOf(internetSite),
            status = ResourceStatus.ONLINE,
        ),
    )

val engineeringWiki =
    Resource.Dns(
        DnsResource(
            id = "0854dca1-2c5b-468a-be85-0eec2f02a211",
            address = "wiki.example.com",
            name = "Engineering wiki",
            addressDescription = "https://wiki.example.com",
            sites = listOf(sydneyOffice),
            status = ResourceStatus.ONLINE,
        ),
    )

private val gitServer =
    Resource.Dns(
        DnsResource(
            id = "92da16a4-0eb2-45c2-b882-8573aad73921",
            address = "git.example.com",
            name = "Git server",
            addressDescription = null,
            sites = listOf(productionCloud),
            status = ResourceStatus.UNKNOWN,
        ),
    )

private val officeNetwork =
    Resource.Cidr(
        CidrResource(
            id = "be575d17-b0b3-40c9-ac34-e1ec3064d75a",
            address = "192.0.2.0/24",
            name = "Office network",
            addressDescription = null,
            sites = listOf(sydneyOffice),
            status = ResourceStatus.ONLINE,
        ),
    )

private val labTestBench =
    Resource.Cidr(
        CidrResource(
            id = "6b15c815-cefc-4128-8ab0-d9d6a526bbc7",
            address = "203.0.113.0/24",
            name = "Lab test bench",
            addressDescription = null,
            sites = listOf(hardwareLab),
            status = ResourceStatus.OFFLINE,
        ),
    )

val benchController =
    ConnectedDevice(
        id = "a21c9663-4d0e-4f4a-a8fa-48790b1e5cef",
        name = "bench-controller-01",
        tunIpv4 = "100.64.3.18",
        tunIpv6 = "fd00:2021:1111::12",
        pools = listOf("Lab hardware", "Shared storage"),
    )

private val designNas =
    ConnectedDevice(
        id = "c4f0a2d7-6b19-4e83-9a5c-1d7e8b3f2a06",
        name = "design-nas",
        tunIpv4 = "100.64.3.24",
        tunIpv6 = "fd00:2021:1111::18",
        pools = listOf("Shared storage"),
    )

// Every resource kind, and a site in each status, so one launch shows the whole session screen.
val mockResources = listOf(internetResource, engineeringWiki, gitServer, officeNetwork, labTestBench)

val mockConnectedDevices = listOf(benchController, designNas)
