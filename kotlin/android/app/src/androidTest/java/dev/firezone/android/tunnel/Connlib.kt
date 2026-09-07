// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.tunnel

import uniffi.connlib.ConnectedDevice
import uniffi.connlib.DisconnectError
import uniffi.connlib.DnsResource
import uniffi.connlib.InternetResource
import uniffi.connlib.NoHandle
import uniffi.connlib.Resource
import uniffi.connlib.ResourceStatus
import uniffi.connlib.Site

// UniFFI hands out `NoHandle` constructors precisely so foreign code can build these
// without a live Rust object behind them.
class FakeDisconnectError(
    private val signInRequired: Boolean,
    private val text: String = "session ended",
) : DisconnectError(NoHandle) {
    override fun userMessage(): String = text

    override fun logMessage(): String = text

    override fun requiresSignIn(): Boolean = signInRequired
}

// The deployment the screenshot fixtures describe, so the galleries and these tests tell one story.
const val ACTOR_NAME = "Jane Doe"
const val ACCOUNT_SLUG = "example-corp"

val engineeringWiki =
    Resource.Dns(
        DnsResource(
            id = "0854dca1-2c5b-468a-be85-0eec2f02a211",
            address = "wiki.example.com",
            name = "Engineering wiki",
            addressDescription = "https://wiki.example.com",
            sites = listOf(Site(id = "917e9354-26b3-4704-867c-f84c8688d269", name = "Sydney Office")),
            status = ResourceStatus.ONLINE,
        ),
    )

val internetResource =
    Resource.Internet(
        InternetResource(
            id = "425233f2-a1cb-4b7d-84f3-850367fa122a",
            name = "Internet Resource",
            sites = listOf(Site(id = "1a4f0f4e-8f3f-4a2e-9b6d-3c5e7a1b2d40", name = "Internet")),
            status = ResourceStatus.ONLINE,
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
