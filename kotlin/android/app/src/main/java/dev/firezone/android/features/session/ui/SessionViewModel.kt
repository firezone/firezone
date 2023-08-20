package dev.firezone.android.features.session.ui

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
    private val actionMutableLiveData = MutableLiveData<ViewAction>()
    val actionLiveData: LiveData<ViewAction> = actionMutableLiveData

    fun startSession() {
        viewModelScope.launch {
            
            sessionManager.connect()
        }
    }

    fun onDisconnect() {
        actionMutableLiveData.postValue(ViewAction.NavigateToSignInFragment)
    }

    internal sealed class ViewAction {

        object NavigateToSignInFragment : ViewAction()

        object ShowError : ViewAction()
    }
}
