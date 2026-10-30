// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.tunnel

import uniffi.connlib.Cidr
import uniffi.connlib.Event

// The interface connlib hands the service once the portal has assigned this Client its addresses.
// The routes deliberately exclude a default route so the tunnel a test establishes cannot take the
// emulator's own connectivity with it.
fun tunInterface(
    ipv4: String = "100.64.0.1",
    ipv6: String = "fd00:2021:1111::1",
) = Event.TunInterfaceUpdated(
    ipv4 = ipv4,
    ipv6 = ipv6,
    dns = listOf("100.100.111.1"),
    searchDomain = null,
    ipv4Routes = listOf(Cidr("100.64.0.0", 11u), Cidr("100.100.111.0", 24u)),
    ipv6Routes = listOf(Cidr("fd00:2021:1111::", 107u), Cidr("fd00:2021:1111:8000::", 107u)),
)

// Multicast passes `VpnService.Builder`'s own validation and the kernel then refuses it, which is
// how a device that will not take one of our addresses fails the entire interface.
const val UNASSIGNABLE_IPV6 = "ff02::1"
