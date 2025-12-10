// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.session.ui

import android.view.View
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.ViewModel
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.core.data.Favorites
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.data.ResourceState
import dev.firezone.android.tunnel.TunnelService.Companion.State
import dev.firezone.android.tunnel.model.Resource
import dev.firezone.android.tunnel.model.isInternetResource
import kotlinx.coroutines.flow.StateFlow
import javax.inject.Inject

@HiltViewModel
internal class SessionViewModel
    @Inject
    constructor() : ViewModel() {
        // Must be `internal` because Dagger does not support injection into `private` fields
        @Inject
        internal lateinit var repo: Repository
        private val _serviceStatusLiveData = MutableLiveData<State>()
        private val _resourcesLiveData = MutableLiveData<List<Resource>>(emptyList())
        private var selectedTab = RESOURCES_TAB_FAVORITES

        val serviceStatusLiveData: MutableLiveData<State>
            get() = _serviceStatusLiveData
        val resourcesLiveData: MutableLiveData<List<Resource>>
            get() = _resourcesLiveData
        val favorites: StateFlow<Favorites>
            get() = repo.favorites

        // Actor name
        fun clearActorName() = repo.clearActorName()

        fun getActorName() = repo.getActorNameSync()

        fun addFavoriteResource(id: String) {
            repo.addFavoriteResource(id)
        }

        fun removeFavoriteResource(id: String) {
            repo.removeFavoriteResource(id)
        }

        fun clearToken() = repo.clearToken()

        // The subset of Resources to actually render
        fun resourcesList(isInternetResourceEnabled: ResourceState): List<ResourceViewModel> {
            val resources =
                resourcesLiveData.value!!.map {
                    if (it.isInternetResource()) {
                        ResourceViewModel(it, isInternetResourceEnabled)
                    } else {
                        ResourceViewModel(it, ResourceState.ENABLED)
                    }
                }

            return if (repo.favorites.value.inner
                    .isEmpty()
            ) {
                resources
            } else if (selectedTab == RESOURCES_TAB_FAVORITES) {
                resources.filter {
                    repo.favorites.value.inner
                        .contains(it.id)
                }
            } else {
                resources
            }
        }

        fun forceTab(): Int? =
            if (repo.favorites.value.inner
                    .isEmpty()
            ) {
                RESOURCES_TAB_ALL
            } else {
                null
            }

        fun tabSelected(position: Int) {
            selectedTab = position
        }

        fun isFavorite(id: String) =
            repo.favorites.value.inner
                .contains(id)

        fun tabLayoutVisibility(): Int =
            if (repo.favorites.value.inner
                    .isNotEmpty()
            ) {
                View.VISIBLE
            } else {
                View.GONE
            }

        companion object {
            private const val RESOURCES_TAB_FAVORITES = 0
            private const val RESOURCES_TAB_ALL = 1
        }
    }
