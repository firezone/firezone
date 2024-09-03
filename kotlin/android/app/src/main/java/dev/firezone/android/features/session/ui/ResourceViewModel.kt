/* Licensed under Apache 2.0 (C) 2024 Firezone, Inc. */
package dev.firezone.android.features.session.ui

import dev.firezone.android.core.data.ON_SYMBOL
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
    var canBeDisabled: Boolean,
    var state: ResourceState,
)

fun internetResourceDisplayName(resource: Resource, state: ResourceState): String {
    return if (!resource.canBeDisabled) {
        "$ON_SYMBOL ${resource.name}"
    } else {
        "${state.stateSymbol()} ${resource.name}"
    }
}

fun displayName(resource: Resource, state: ResourceState): String {
    if (resource.isInternetResource()) {
        return internetResourceDisplayName(resource, state)
    } else {
        return resource.name
    }
}

fun Resource.toViewResource(resourceState: ResourceState): ResourceViewModel {
    return ResourceViewModel(
        id = this.id,
        type = this.type,
        address = this.address,
        addressDescription = this.addressDescription,
        sites = this.sites,
        name = this.name,
        displayName = displayName(this, resourceState),
        status = this.status,
        canBeDisabled = this.canBeDisabled,
        state = resourceState,
    )
}

fun ResourceViewModel.isInternetResource(): Boolean {
    return this.type == ResourceType.Internet
}

