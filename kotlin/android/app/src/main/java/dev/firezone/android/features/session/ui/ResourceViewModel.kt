/* Licensed under Apache 2.0 (C) 2024 Firezone, Inc. */
package dev.firezone.android.features.session.ui

import dev.firezone.android.core.data.ResourceState
import dev.firezone.android.core.data.stateSymbol
import dev.firezone.android.tunnel.model.Resource
import dev.firezone.android.tunnel.model.ResourceType
import dev.firezone.android.tunnel.model.Site
import dev.firezone.android.tunnel.model.StatusEnum
import dev.firezone.android.tunnel.model.isInternetResource

data class ResourceViewModel(
    val id: String,
    val type: ResourceType,
    val address: String?,
    val addressDescription: String?,
    val sites: List<Site>?,
    val displayName: String,
    val name: String,
    val status: StatusEnum,
    var state: ResourceState,
)

fun internetResourceDisplayName(
    resource: Resource,
    state: ResourceState,
): String {
    return "${state.stateSymbol()} ${resource.name}"
}

fun Resource.toResourceViewModel(resourceState: ResourceState): ResourceViewModel {
    return ResourceViewModel(
        id = this.id,
        type = this.type,
        address = this.address,
        addressDescription = this.addressDescription,
        sites = this.sites,
        name = this.name,
        displayName = displayName(this, resourceState),
        status = this.status,
        state = resourceState,
    )
}

fun displayName(
    resource: Resource,
    state: ResourceState,
): String {
    if (resource.isInternetResource()) {
        return internetResourceDisplayName(resource, state)
    } else {
        return resource.name
    }
}

fun ResourceViewModel.isInternetResource(): Boolean {
    return this.type == ResourceType.Internet
}
