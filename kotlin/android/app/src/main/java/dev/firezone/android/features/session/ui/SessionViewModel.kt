/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.features.session.ui

import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.ViewModel
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.core.data.PreferenceRepository
import dev.firezone.android.tunnel.TunnelService.Companion.State
import dev.firezone.android.tunnel.model.Resource
import javax.inject.Inject

@HiltViewModel
internal class SessionViewModel
    @Inject
    constructor() : ViewModel() {
        @Inject
        internal lateinit var repo: PreferenceRepository
        private val _serviceStatusLiveData = MutableLiveData<State>()
        private val _resourcesLiveData = MutableLiveData<List<Resource>>(emptyList())

        val serviceStatusLiveData: MutableLiveData<State>
            get() = _serviceStatusLiveData
        val resourcesLiveData: MutableLiveData<List<Resource>>
            get() = _resourcesLiveData

        fun clearToken() = repo.clearToken()

        fun getActorName() = repo.getConfigSync().actorName
    }
