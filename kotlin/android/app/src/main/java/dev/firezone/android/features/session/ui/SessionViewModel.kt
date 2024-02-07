/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.features.session.ui

import android.content.Context
import android.util.Log
import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.tunnel.TunnelService
import dev.firezone.android.tunnel.TunnelService.Companion.State
import dev.firezone.android.tunnel.model.Resource
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
internal class SessionViewModel
    @Inject
    constructor() : ViewModel() {
        private val _uiState = MutableStateFlow(UiState(TunnelService.activeTunnel?.tunnelState ?: State.DOWN))
        val uiState: StateFlow<UiState> = _uiState

        private val actionMutableLiveData = MutableLiveData<ViewAction>()
        val actionLiveData: LiveData<ViewAction> = actionMutableLiveData

        fun signIn(context: Context) {
            viewModelScope.launch {
                if (TunnelService.activeTunnel == null ||
                    TunnelService.activeTunnel?.tunnelState == State.DOWN ||
                    TunnelService.activeTunnel?.tunnelState == State.CLOSED
                ) {
                    TunnelService.start(context)
                } else {
                    _uiState.value =
                        _uiState.value.copy(
                            state = TunnelService.activeTunnel!!.tunnelState,
                            resources = TunnelService.activeTunnel!!.tunnelResources,
                        )
                }
            }
        }

        fun signOut(context: Context) {
            TunnelService.stop(context)
        }

        private fun onClosed() {
            actionMutableLiveData.postValue(ViewAction.NavigateToSignIn)
        }

        internal data class UiState(
            val state: State? = State.DOWN,
            val resources: List<Resource>? = emptyList(),
        )

        internal sealed class ViewAction {
            object NavigateToSignIn : ViewAction()

            object ShowError : ViewAction()
        }
    }
