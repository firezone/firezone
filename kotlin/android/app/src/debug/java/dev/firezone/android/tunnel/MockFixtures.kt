// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.tunnel

import uniffi.connlib.CidrResource
import uniffi.connlib.ConnectedDevice
import uniffi.connlib.DnsResource
import uniffi.connlib.InternetResource
import uniffi.connlib.Resource
import uniffi.connlib.ResourceStatus
import uniffi.connlib.Site

// The one deployment this app is shown against: the mock session serves it, the screenshot
// galleries render it and the end-to-end tests assert on it. In the shape connlib reports, so the
// mock reaches the UI through the same conversion a real session does.
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

private val internalServices =
    Resource.Dns(
        DnsResource(
            id = "ed3778b9-dd41-4312-b616-028b0bbaff1c",
            address = "*.svc.example.com",
            name = "Internal services",
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

private val productionVpc =
    Resource.Cidr(
        CidrResource(
            id = "8900accd-e39d-4705-ac7c-2189c59b4a1c",
            address = "198.51.100.0/24",
            name = "Production VPC",
            addressDescription = null,
            sites = listOf(productionCloud),
            status = ResourceStatus.UNKNOWN,
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

// Every resource kind, and a site in each status, so one launch shows the whole session screen.
val mockResources =
    listOf(
        internetResource,
        engineeringWiki,
        gitServer,
        internalServices,
        officeNetwork,
        productionVpc,
        labTestBench,
    )

// More devices than fit on a screen, so that a scrolled capture has something to scroll.
val mockConnectedDevices =
    listOf(
        benchController,
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
            id = "f0442658-4fca-4f53-9323-161fa389a659",
            name = "build-runner-04",
            tunIpv4 = "100.64.7.43",
            tunIpv6 = "fd00:2021:1111::2b",
            pools = listOf("Build farm"),
        ),
        ConnectedDevice(
            id = "7392a499-c8f0-4f24-aba0-2f6a00fe3bc0",
            name = "build-runner-05",
            tunIpv4 = "100.64.7.44",
            tunIpv6 = "fd00:2021:1111::2c",
            pools = listOf("Build farm"),
        ),
        ConnectedDevice(
            id = "62f5c6e4-46f5-418a-82ff-7d0e612b29a6",
            name = "build-runner-06",
            tunIpv4 = "100.64.7.45",
            tunIpv6 = "fd00:2021:1111::2d",
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
            id = "4a6f80e6-5322-4202-a1ac-1e897aa826a5",
            name = "lab-probe-01",
            tunIpv4 = "100.64.19.87",
            tunIpv6 = "fd00:2021:1111::3c2",
            pools = listOf("Lab hardware"),
        ),
        ConnectedDevice(
            id = "99fd7f50-02aa-4ebd-aac3-b9b914c4aebb",
            name = "lab-probe-02",
            tunIpv4 = "100.64.19.88",
            tunIpv6 = "fd00:2021:1111::3c3",
            pools = listOf("Lab hardware"),
        ),
        ConnectedDevice(
            id = "3683defa-c0c5-453b-8d06-22fe7f422f05",
            name = "media-encoder-01",
            tunIpv4 = "100.64.11.6",
            tunIpv6 = "fd00:2021:1111::1f6",
            pools = listOf("Shared storage"),
        ),
        ConnectedDevice(
            id = "cef0ac7a-c103-4e1a-b937-485d6fc8f00c",
            name = "render-node-01",
            tunIpv4 = "100.64.7.46",
            tunIpv6 = "fd00:2021:1111::2e",
            pools = listOf("Build farm", "Shared storage"),
        ),
        ConnectedDevice(
            id = "ef39322d-65e2-4dea-af50-6fd4c61a72a6",
            name = "sensor-hub-01",
            tunIpv4 = "100.64.19.89",
            tunIpv6 = "fd00:2021:1111::3c4",
            pools = listOf("Lab hardware"),
        ),
        ConnectedDevice(
            id = "487f8ebe-4b83-4239-8cb9-40d298fe8561",
            name = "sensor-hub-02",
            tunIpv4 = "100.64.19.90",
            tunIpv6 = "fd00:2021:1111::3c5",
            pools = listOf("Lab hardware"),
        ),
        ConnectedDevice(
            id = "e8dc5d0d-93ac-4e1b-9532-866dda67ce5b",
            name = "vision-rig-01",
            tunIpv4 = "100.64.19.86",
            tunIpv6 = "fd00:2021:1111::3c1",
            pools = listOf("Lab hardware"),
        ),
        ConnectedDevice(
            id = "46b198aa-fcf6-4640-bb23-b20879c52958",
            name = "vision-rig-02",
            tunIpv4 = "100.64.19.91",
            tunIpv6 = "fd00:2021:1111::3c6",
            pools = listOf("Lab hardware"),
        ),
    )
