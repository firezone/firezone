// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.session.ui

import dev.firezone.android.core.data.ResourceState
import dev.firezone.android.core.data.stateSymbol
import dev.firezone.android.tunnel.model.Resource
import dev.firezone.android.tunnel.model.ResourceType
import dev.firezone.android.tunnel.model.Site
import dev.firezone.android.tunnel.model.StatusEnum
import dev.firezone.android.tunnel.model.isInternetResource

class ResourceViewModel(
    resource: Resource,
    resourceState: ResourceState,
) {
    val id: String = resource.id
    val type: ResourceType = resource.type
    val address: String? = resource.address
    val addressDescription: String? = resource.addressDescription
    val sites: List<Site>? = resource.sites
    val displayName: String = displayName(resource, resourceState)
    val name: String = resource.name
    val status: StatusEnum = resource.status
    var state: ResourceState = resourceState
}

fun displayName(
    resource: Resource,
    state: ResourceState,
): String =
    if (resource.isInternetResource()) {
        internetResourceDisplayName(resource, state)
    } else {
        resource.name
    }

fun internetResourceDisplayName(
    resource: Resource,
    state: ResourceState,
): String = "${state.stateSymbol()} ${resource.name}"

fun ResourceViewModel.isInternetResource(): Boolean = this.type == ResourceType.Internet
