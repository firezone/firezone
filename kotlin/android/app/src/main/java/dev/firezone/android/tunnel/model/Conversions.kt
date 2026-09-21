// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.tunnel.model

// UniFFI -> Model type conversions.

internal fun uniffi.connlib.Resource.toModel(): Resource =
    when (this) {
        is uniffi.connlib.Resource.Dns -> {
            resource.let { r ->
                Resource(
                    ResourceType.DNS,
                    r.id,
                    r.address,
                    r.addressDescription,
                    r.sites.map { it.toModel() },
                    r.name,
                    r.status.toModel(),
                )
            }
        }

        is uniffi.connlib.Resource.Cidr -> {
            resource.let { r ->
                Resource(
                    ResourceType.CIDR,
                    r.id,
                    r.address,
                    r.addressDescription,
                    r.sites.map { it.toModel() },
                    r.name,
                    r.status.toModel(),
                )
            }
        }

        // The internet resource covers everything, so it carries no address of its own.
        is uniffi.connlib.Resource.Internet -> {
            resource.let { r ->
                Resource(
                    ResourceType.Internet,
                    r.id,
                    null,
                    null,
                    r.sites.map { it.toModel() },
                    r.name,
                    r.status.toModel(),
                )
            }
        }
    }

internal fun uniffi.connlib.ConnectedDevice.toModel(): ConnectedDevice =
    ConnectedDevice(
        id = id,
        name = name,
        tunIpv4 = tunIpv4,
        tunIpv6 = tunIpv6,
        pools = pools,
    )

private fun uniffi.connlib.Site.toModel() = Site(id = id, name = name)

private fun uniffi.connlib.ResourceStatus.toModel() =
    when (this) {
        uniffi.connlib.ResourceStatus.UNKNOWN -> StatusEnum.UNKNOWN
        uniffi.connlib.ResourceStatus.ONLINE -> StatusEnum.ONLINE
        uniffi.connlib.ResourceStatus.OFFLINE -> StatusEnum.OFFLINE
    }
