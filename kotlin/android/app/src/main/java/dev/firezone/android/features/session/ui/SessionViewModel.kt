/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.features.session.ui

import android.content.Context
import android.util.Log
import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.tunnel.TunnelManager
import dev.firezone.android.tunnel.TunnelService
import dev.firezone.android.tunnel.callback.TunnelListener
import dev.firezone.android.tunnel.data.TunnelRepository
import dev.firezone.android.tunnel.model.Resource
import dev.firezone.android.tunnel.model.Tunnel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
internal class SessionViewModel
    @Inject
    constructor(
        private val tunnelManager: TunnelManager,
        private val tunnelRepository: TunnelRepository,
    ) : ViewModel() {
        private val _uiState = MutableStateFlow(UiState())
        val uiState: StateFlow<UiState> = _uiState

        private val actionMutableLiveData = MutableLiveData<ViewAction>()
        val actionLiveData: LiveData<ViewAction> = actionMutableLiveData

        private val tunnelListener =
            object : TunnelListener {
                override fun onTunnelStateUpdate(state: Tunnel.State) {
                    when (state) {
                        Tunnel.State.Down -> {
                            onDisconnect()
                        }
                        Tunnel.State.Closed -> {
                            onClosed()
                        }
                        else -> {
                            _uiState.value =
                                _uiState.value.copy(
                                    state = state,
                                )
                        }
                    }
                }

                override fun onResourcesUpdate(resources: List<Resource>) {
                    Log.d("TunnelManager", "onUpdateResources: $resources")
                    _uiState.value =
                        _uiState.value.copy(
                            resources = resources,
                        )
                }

                override fun onError(error: String): Boolean {
                    // TODO("Not yet implemented")
                    return true
                }
            }

        fun connect(context: Context) {
            viewModelScope.launch {
                tunnelManager.addListener(tunnelListener)

                val isServiceRunning = TunnelService.isRunning(context)
                if (!isServiceRunning ||
                    tunnelRepository.getState() == Tunnel.State.Down ||
                    tunnelRepository.getState() == Tunnel.State.Closed
                ) {
                    tunnelManager.connect()
                } else {
                    _uiState.value =
                        _uiState.value.copy(
                            state = tunnelRepository.getState(),
                            resources = tunnelRepository.getResources(),
                        )
                }
            }
        }

        override fun onCleared() {
            super.onCleared()

            tunnelManager.removeListener(tunnelListener)
        }

        fun disconnect() {
            tunnelManager.disconnect()
        }

        private fun onDisconnect() {
            // no-op
        }

        private fun onClosed() {
            tunnelManager.removeListener(tunnelListener)
            actionMutableLiveData.postValue(ViewAction.NavigateToSignIn)
        }

        internal data class UiState(
            val state: Tunnel.State = Tunnel.State.Down,
            val resources: List<Resource>? = null,
        )

        internal sealed class ViewAction {
            object NavigateToSignIn : ViewAction()

            object ShowError : ViewAction()
        }
    }
