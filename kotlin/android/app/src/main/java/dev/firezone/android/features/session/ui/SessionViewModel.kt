package dev.firezone.android.features.session.ui

import android.util.Log
import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.tunnel.callback.TunnelListener
import dev.firezone.android.tunnel.TunnelManager
import dev.firezone.android.tunnel.model.Resource
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import javax.inject.Inject
import kotlinx.coroutines.launch

@HiltViewModel
internal class SessionViewModel @Inject constructor(
    private val tunnelManager: TunnelManager,
) : ViewModel() {
    private val _uiState = MutableStateFlow(UiState())
    val uiState: StateFlow<UiState> = _uiState

    private val actionMutableLiveData = MutableLiveData<ViewAction>()
    val actionLiveData: LiveData<ViewAction> = actionMutableLiveData

    private val tunnelListener = object: TunnelListener {
        override fun onSetInterfaceConfig(
            tunnelAddressIPv4: String,
            tunnelAddressIPv6: String,
            dnsAddress: String,
            dnsFallbackStrategy: String
        ) {
            //TODO("Not yet implemented")
        }

        override fun onTunnelReady(): Boolean {
            //TODO("Not yet implemented")
            return true
        }

        override fun onAddRoute(cidrAddress: String) {
            //TODO("Not yet implemented")
        }

        override fun onRemoveRoute(cidrAddress: String) {
            //TODO("Not yet implemented")
        }

        override fun onUpdateResources(resources: List<Resource>) {
            //TODO("Not yet implemented")
            Log.d("TunnelManager", "onUpdateResources: $resources")
            _uiState.value = _uiState.value.copy (
                resources = resources
            )
        }

        override fun onDisconnect(error: String?): Boolean {
            //TODO("Not yet implemented")
            return true
        }

        override fun onError(error: String): Boolean {
            //TODO("Not yet implemented")
            return true
        }
    }

    fun startSession() {
        viewModelScope.launch {
            tunnelManager.addListener(tunnelListener)
            tunnelManager.connect()
        }
    }

    override fun onCleared() {
        super.onCleared()

        tunnelManager.removeListener(tunnelListener)
    }

    fun onDisconnect() {
        actionMutableLiveData.postValue(ViewAction.NavigateToSignInFragment)
    }

    internal data class UiState(
        val resources: List<Resource>? = null,
    )

    internal sealed class ViewAction {

        object NavigateToSignInFragment : ViewAction()

        object ShowError : ViewAction()
    }
}
