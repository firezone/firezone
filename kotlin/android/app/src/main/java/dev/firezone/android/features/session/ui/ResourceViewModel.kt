// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.session.ui

import androidx.compose.runtime.Immutable
import dev.firezone.android.core.data.ResourceState
import dev.firezone.android.tunnel.model.Resource
import dev.firezone.android.tunnel.model.ResourceType
import dev.firezone.android.tunnel.model.Site
import dev.firezone.android.tunnel.model.StatusEnum

@Immutable
class ResourceViewModel(
    resource: Resource,
    resourceState: ResourceState,
) {
    val id: String = resource.id
    val type: ResourceType = resource.type
    val address: String? = resource.address
    val addressDescription: String? = resource.addressDescription
    val sites: List<Site>? = resource.sites
    // The on/off state is shown with a globe icon, so the name needs no prefix.
    val displayName: String = resource.name
    val name: String = resource.name
    val status: StatusEnum = resource.status
    val state: ResourceState = resourceState
}

fun ResourceViewModel.isInternetResource(): Boolean = this.type == ResourceType.Internet
