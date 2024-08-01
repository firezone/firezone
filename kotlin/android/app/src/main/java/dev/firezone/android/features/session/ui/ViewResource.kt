package dev.firezone.android.features.session.ui

import dev.firezone.android.tunnel.model.Resource
import dev.firezone.android.tunnel.model.Site
import dev.firezone.android.tunnel.model.StatusEnum

data class ViewResource(
    val id: String,
    val address: String,
    val addressDescription: String?,
    val sites: List<Site>?,
    val name: String,
    val status: StatusEnum,
    var enabled: Boolean = true,
    var disableable: Boolean = true,
    )

fun Resource.toViewResource(): ViewResource {
    return ViewResource(
        id = this.id,
        address = this.address,
        addressDescription = this.addressDescription,
        sites = this.sites,
        name = this.name,
        status = this.status,
        enabled = true,
        disableable = this.disableable
    )
}