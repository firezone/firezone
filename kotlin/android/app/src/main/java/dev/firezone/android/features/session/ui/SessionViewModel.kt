/* Licensed under Apache 2.0 (C) 2024 Firezone, Inc. */
package dev.firezone.android.features.session.ui

import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.ViewModel
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.core.data.Repository
import dev.firezone.android.tunnel.TunnelService.Companion.State
import dev.firezone.android.tunnel.model.Resource
import javax.inject.Inject

@HiltViewModel
internal class SessionViewModel
    @Inject
    constructor() : ViewModel() {
        @Inject
        internal lateinit var repo: Repository
        private val _favoriteResourcesLiveData = MutableLiveData<HashSet<String>>(HashSet())
        private val _serviceStatusLiveData = MutableLiveData<State>()
        private val _resourcesLiveData = MutableLiveData<List<Resource>>(emptyList())

        val favoriteResourcesLiveData: MutableLiveData<HashSet<String>>
            get() = _favoriteResourcesLiveData
        val serviceStatusLiveData: MutableLiveData<State>
            get() = _serviceStatusLiveData
        val resourcesLiveData: MutableLiveData<List<Resource>>
            get() = _resourcesLiveData

        // Actor name
        fun clearActorName() = repo.clearActorName()

        fun getActorName() = repo.getActorNameSync()

        fun addFavoriteResource(id: String) {
            val value = _favoriteResourcesLiveData.value!!
            value.add(id)
            repo.saveFavoritesSync(value)
            // Update LiveData
            _favoriteResourcesLiveData.value = value
        }

        fun removeFavoriteResource(id: String) {
            val value = _favoriteResourcesLiveData.value!!
            value.remove(id)
            repo.saveFavoritesSync(value)
            // Update LiveData
            _favoriteResourcesLiveData.value = value
        }

        fun clearToken() = repo.clearToken()
    }
