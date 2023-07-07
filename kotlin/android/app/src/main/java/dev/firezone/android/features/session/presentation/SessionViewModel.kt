package dev.firezone.android.features.session.presentation

import dev.firezone.android.features.session.backend.SessionManager
import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.launch

@HiltViewModel
internal class SessionViewModel @Inject constructor(
    private val sessionManager: SessionManager
) : ViewModel() {
    private val actionMutableLiveData = MutableLiveData<SessionViewAction>()
    val actionLiveData: LiveData<SessionViewAction> = actionMutableLiveData

    fun startSession() {
        viewModelScope.launch {
            sessionManager.connect()
// TODO: Is this needed?
//                .catch {
//                    actionMutableLiveData.postValue(SessionViewAction.ShowError)
//                }
//                .collect {
//                    onConnect()
//                }
        }
    }
// TODO: Is this still needed?
//    private fun onConnect() {
//        viewModelScope.launch(Dispatchers.IO) {
//        }
//    }

    fun onDisconnect() {
        actionMutableLiveData.postValue(SessionViewAction.NavigateToSignInFragment)
    }
}
