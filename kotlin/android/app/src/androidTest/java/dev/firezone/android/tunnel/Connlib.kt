// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.tunnel

import uniffi.connlib.DisconnectError
import uniffi.connlib.DnsResource
import uniffi.connlib.InternetResource
import uniffi.connlib.NoHandle
import uniffi.connlib.Resource
import uniffi.connlib.ResourceStatus

// UniFFI hands out `NoHandle` constructors precisely so foreign code can build these
// without a live Rust object behind them.
class FakeDisconnectError(
    private val signInRequired: Boolean,
    private val text: String = "session ended",
) : DisconnectError(NoHandle) {
    override fun message(): String = text

    override fun requiresSignIn(): Boolean = signInRequired
}

fun dnsResource(
    name: String,
    address: String = "gitlab.example.com",
    id: String = "9e1c1a3a-8a9b-4e3a-9a4a-3b1c0d5e6f70",
) = Resource.Dns(
    DnsResource(
        id = id,
        address = address,
        name = name,
        addressDescription = null,
        sites = emptyList(),
        status = ResourceStatus.ONLINE,
    ),
)

fun connectedDevice(
    name: String,
    id: String = "1d2c3b4a-5f6e-4a7b-8c9d-0e1f2a3b4c5d",
) = uniffi.connlib.ConnectedDevice(
    id = id,
    name = name,
    tunIpv4 = "100.64.0.2",
    tunIpv6 = "fd00:2021:1111::2",
    pools = emptyList(),
)

fun internetResource(id: String = "0854dca1-2c5b-468a-be85-0eec2f02a211") =
    Resource.Internet(
        InternetResource(
            id = id,
            name = "Internet Resource",
            sites = emptyList(),
            status = ResourceStatus.ONLINE,
        ),
    )
