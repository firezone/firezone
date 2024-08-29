/* Licensed under Apache 2.0 (C) 2024 Firezone, Inc. */
package dev.firezone.android.features.session.ui

import dev.firezone.android.tunnel.model.Resource
import dev.firezone.android.tunnel.model.ResourceType
import dev.firezone.android.tunnel.model.Site
import dev.firezone.android.tunnel.model.StatusEnum

data class ViewResource(
    val id: String,
    val type: ResourceType,
    val address: String?,
    val addressDescription: String?,
    val sites: List<Site>?,
    val name: String,
    val status: StatusEnum,
    var enabled: Boolean,
    var canBeDisabled: Boolean = true,
)

fun Resource.toViewResource(enabled: Boolean): ViewResource {
    return ViewResource(
        id = this.id,
        type = this.type,
        address = this.address,
        addressDescription = this.addressDescription,
        sites = this.sites,
        name = this.name,
        status = this.status,
        enabled = enabled,
        canBeDisabled = this.canBeDisabled,
    )
}

fun ViewResource.isInternetResource(): Boolean {
    return this.type == ResourceType.Internet
}
